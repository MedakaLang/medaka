# META
source_lines=2180
stages=DESUGAR,MARK
# SOURCE
import types.runtime_abi_types.{CallableShape(..)}

export
runtimeAbiRows : List (String, CallableShape)
runtimeAbiRows = [
  (
    "putStr",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> <Stdout> Unit",
    },
  ),
  (
    "putStrLn",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> <Stdout> Unit",
    },
  ),
  (
    "ePutStr",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> <Stderr> Unit",
    },
  ),
  (
    "ePutStrLn",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> <Stderr> Unit",
    },
  ),
  (
    "flushStdout",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Unit",
      canonicalSignature = "v1:Unit -> <Stdout> Unit",
    },
  ),
  (
    "readLine",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> <Stdin> String",
    },
  ),
  (
    "readLineOpt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Option",
      canonicalSignature = "v1:Unit -> <Stdin> Option String",
    },
  ),
  (
    "readAll",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> <Stdin> String",
    },
  ),
  (
    "readExactly",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Option",
      canonicalSignature = "v1:Int -> <Stdin> Option String",
    },
  ),
  (
    "Ref",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["a"],
      resultHead = "Ref",
      canonicalSignature = "v1:a -> Ref a",
    },
  ),
  (
    "setRef",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Ref", "a"],
      resultHead = "Unit",
      canonicalSignature = "v1:Ref a -> a -> Unit",
    },
  ),
  (
    "readFile",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileRead path> Result String String",
    },
  ),
  (
    "readFileBytes",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileRead path> Result String (Array Int)",
    },
  ),
  (
    "writeFile",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 3,
      parameterHeads = ["String", "String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> String -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "writeFileBytes",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 3,
      parameterHeads = ["String", "Array"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> Array Int -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "writeFileMode",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 4,
      parameterHeads = ["String", "Int", "String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> Int -> String -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "appendFile",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 3,
      parameterHeads = ["String", "String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> String -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "fileExists",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Bool",
      canonicalSignature = "v1:(path : String) -> <FileRead path> Bool",
    },
  ),
  (
    "fileMode",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileRead path> Result String Int",
    },
  ),
  (
    "canonicalizePath",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "String",
      canonicalSignature = "v1:(path : String) -> <FileRead path> String",
    },
  ),
  (
    "listDir",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileRead path> Result String (List String)",
    },
  ),
  (
    "makeDir",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "removeFile",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "rename",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 4,
      parameterHeads = ["String", "String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(src : String) -> (dst : String) -> <FileWrite src, FileWrite dst> Result String Unit",
    },
  ),
  (
    "fsync",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "removeDir",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileWrite path> Result String Unit",
    },
  ),
  (
    "statFile",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 2,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(path : String) -> <FileRead path> Result String (Int, Bool, Bool, Float)",
    },
  ),
  (
    "args",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "List",
      canonicalSignature = "v1:Unit -> List String",
    },
  ),
  (
    "getEnv",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Option",
      canonicalSignature = "v1:(name : String) -> <Env name> Option String",
    },
  ),
  (
    "executablePath",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> <Env> String",
    },
  ),
  (
    "buildFingerprint",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> String",
    },
  ),
  (
    "buildCommit",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> String",
    },
  ),
  (
    "buildDate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "String",
      canonicalSignature = "v1:Unit -> String",
    },
  ),
  (
    "runCommand",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "List"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(program : String) -> List String -> <Exec program> Result String (Int, String, String)",
    },
  ),
  (
    "runCommandBatch",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["String", "Int", "List"],
      resultHead = "List",
      canonicalSignature =
        "v1:(program : String) -> Int -> List (List String) -> <Exec program> List (Result String (Int, String, String))",
    },
  ),
  (
    "exit",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Unit",
      canonicalSignature = "v1:Int -> Unit",
    },
  ),
  (
    "panic",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "a",
      canonicalSignature = "v1:String -> a",
    },
  ),
  (
    "indexError",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "a",
      canonicalSignature = "v1:String -> a",
    },
  ),
  (
    "indexErrorAt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "a",
      canonicalSignature = "v1:Int -> a",
    },
  ),
  (
    "indexErrorAtSite",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "a",
      canonicalSignature = "v1:Int -> Int -> a",
    },
  ),
  (
    "panicAt",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "String"],
      resultHead = "a",
      canonicalSignature = "v1:Int -> String -> a",
    },
  ),
  (
    "sliceError",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "a",
      canonicalSignature = "v1:Int -> Int -> a",
    },
  ),
  (
    "stashRunStdout",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> Unit",
    },
  ),
  (
    "enableRunStdoutFlush",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Unit",
      canonicalSignature = "v1:Unit -> Unit",
    },
  ),
  (
    "__fallthrough__",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "a",
      canonicalSignature = "v1:Unit -> a",
    },
  ),
  (
    "assertSnapshot",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Unit",
      canonicalSignature = "v1:String -> String -> <IO> Unit",
    },
  ),
  (
    "netResolve",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(host : String) -> <Net host> Result String (List String)",
    },
  ),
  (
    "netTcpConnect",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(host : String) -> Int -> <Net host> Result String (Socket host)",
    },
  ),
  (
    "netTcpListen",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(host : String) -> Int -> <Net host> Result String (ListenSocket host)",
    },
  ),
  (
    "netListenPort",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ListenSocket"],
      resultHead = "Result",
      canonicalSignature = "v1:ListenSocket a -> <Net a> Result String Int",
    },
  ),
  (
    "netTcpAccept",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ListenSocket"],
      resultHead = "Result",
      canonicalSignature =
        "v1:ListenSocket a -> <Net a> Result String (Socket a)",
    },
  ),
  (
    "netSend",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Array"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Array Int -> <Net h> Result String Int",
    },
  ),
  (
    "netSendFrom",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Socket", "Array", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Array Int -> Int -> <Net h> Result String Int",
    },
  ),
  (
    "netRecv",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Int -> <Net h> Result String (Array Int)",
    },
  ),
  (
    "netShutdown",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Int"],
      resultHead = "Result",
      canonicalSignature = "v1:Socket h -> Int -> <Net h> Result String Unit",
    },
  ),
  (
    "netClose",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Socket"],
      resultHead = "Result",
      canonicalSignature = "v1:Socket h -> <Net h> Result String Unit",
    },
  ),
  (
    "netCloseListener",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ListenSocket"],
      resultHead = "Result",
      canonicalSignature = "v1:ListenSocket a -> <Net a> Result String Unit",
    },
  ),
  (
    "netSetTimeout",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Int"],
      resultHead = "Result",
      canonicalSignature = "v1:Socket h -> Int -> <Net h> Result String Unit",
    },
  ),
  (
    "socketFd",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Socket"],
      resultHead = "Int",
      canonicalSignature = "v1:Socket h -> Int",
    },
  ),
  (
    "listenSocketFd",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ListenSocket"],
      resultHead = "Int",
      canonicalSignature = "v1:ListenSocket a -> Int",
    },
  ),
  (
    "pdsSignalStart",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Result",
      canonicalSignature = "v1:Unit -> <Signal> Result String Int",
    },
  ),
  (
    "pdsSignalRequested",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Bool",
      canonicalSignature = "v1:Unit -> <Signal> Bool",
    },
  ),
  (
    "ioPoll",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Array", "Array", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Array Int -> Array Int -> Int -> <Clock> Result String (Array Int)",
    },
  ),
  (
    "netSetNonblock",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Bool"],
      resultHead = "Result",
      canonicalSignature = "v1:Socket h -> Bool -> <Net h> Result String Unit",
    },
  ),
  (
    "netSetNonblockListener",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["ListenSocket", "Bool"],
      resultHead = "Result",
      canonicalSignature =
        "v1:ListenSocket a -> Bool -> <Net a> Result String Unit",
    },
  ),
  (
    "netTryAccept",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ListenSocket"],
      resultHead = "Result",
      canonicalSignature =
        "v1:ListenSocket a -> <Net a> Result String (Option (Socket a))",
    },
  ),
  (
    "netConnectStart",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:(host : String) -> Int -> <Net host> Result String (Socket host)",
    },
  ),
  (
    "netConnectCheck",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Socket"],
      resultHead = "Result",
      canonicalSignature = "v1:Socket h -> <Net h> Result String (Option Unit)",
    },
  ),
  (
    "netTryRecv",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Int -> <Net h> Result String (Option (Array Int))",
    },
  ),
  (
    "netTryRecvBytes",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Int -> <Net h> Result String (Option ByteBlock)",
    },
  ),
  (
    "netTrySend",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Socket", "Array"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Array Int -> <Net h> Result String (Option Int)",
    },
  ),
  (
    "netTrySendFrom",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Socket", "Array", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> Array Int -> Int -> <Net h> Result String (Option Int)",
    },
  ),
  (
    "netSendBytesFrom",
    CallableShape {
      writtenValueArity = 4,
      loweredCoreArity = 4,
      parameterHeads = ["Socket", "ByteBlock", "Int", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String Int",
    },
  ),
  (
    "netTrySendBytesFrom",
    CallableShape {
      writtenValueArity = 4,
      loweredCoreArity = 4,
      parameterHeads = ["Socket", "ByteBlock", "Int", "Int"],
      resultHead = "Result",
      canonicalSignature =
        "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String (Option Int)",
    },
  ),
  (
    "wallTimeSec",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Float",
      canonicalSignature = "v1:Unit -> <Clock> Float",
    },
  ),
  (
    "monotonicSec",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Float",
      canonicalSignature = "v1:Unit -> <Clock> Float",
    },
  ),
  (
    "sleepMs",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Unit",
      canonicalSignature = "v1:Int -> <Clock> Unit",
    },
  ),
  (
    "fetchText",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Result",
      canonicalSignature = "v1:(url : String) -> <Net url> Result String String",
    },
  ),
  (
    "allocBytes",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Float",
      canonicalSignature = "v1:Unit -> <IO> Float",
    },
  ),
  (
    "randomInt",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> <Rand> Int",
    },
  ),
  (
    "randomBool",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Bool",
      canonicalSignature = "v1:Unit -> <Rand> Bool",
    },
  ),
  (
    "randomFloat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Float",
      canonicalSignature = "v1:Unit -> <Rand> Float",
    },
  ),
  (
    "randomChar",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "Char",
      canonicalSignature = "v1:Unit -> <Rand> Char",
    },
  ),
  (
    "setSeed",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Unit",
      canonicalSignature = "v1:Int -> <Rand> Unit",
    },
  ),
  (
    "randomState",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Unit"],
      resultHead = "U64",
      canonicalSignature = "v1:Unit -> <Rand> U64",
    },
  ),
  (
    "restoreRandomState",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U64"],
      resultHead = "Unit",
      canonicalSignature = "v1:U64 -> <Rand> Unit",
    },
  ),
  (
    "osEntropyBytes",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Array",
      canonicalSignature = "v1:Int -> <Rand> Array Int",
    },
  ),
  (
    "hashInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int",
    },
  ),
  (
    "hashFloat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Int",
      canonicalSignature = "v1:Float -> Int",
    },
  ),
  (
    "hashString",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Int",
      canonicalSignature = "v1:String -> Int",
    },
  ),
  (
    "hashChar",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Int",
      canonicalSignature = "v1:Char -> Int",
    },
  ),
  (
    "hashBool",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Bool"],
      resultHead = "Int",
      canonicalSignature = "v1:Bool -> Int",
    },
  ),
  (
    "pi",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Float",
      canonicalSignature = "v1:Float",
    },
  ),
  (
    "e",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Float",
      canonicalSignature = "v1:Float",
    },
  ),
  (
    "intMinBound",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Int",
      canonicalSignature = "v1:Int",
    },
  ),
  (
    "intMaxBound",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Int",
      canonicalSignature = "v1:Int",
    },
  ),
  (
    "charMinBound",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Char",
      canonicalSignature = "v1:Char",
    },
  ),
  (
    "charMaxBound",
    CallableShape {
      writtenValueArity = 0,
      loweredCoreArity = 0,
      parameterHeads = [],
      resultHead = "Char",
      canonicalSignature = "v1:Char",
    },
  ),
  (
    "intToFloat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Float",
      canonicalSignature = "v1:Int -> Float",
    },
  ),
  (
    "floatToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Int",
      canonicalSignature = "v1:Float -> Int",
    },
  ),
  (
    "floatRem",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Float", "Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float -> Float",
    },
  ),
  (
    "bitAnd",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "bitOr",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "bitXor",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "shiftLeft",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "shiftRight",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "bitNot",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int",
    },
  ),
  (
    "sqrt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "cbrt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "exp",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "log",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "log2",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "log10",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "sin",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "cos",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "tan",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "asin",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "acos",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "atan",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "sinh",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "cosh",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "tanh",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "floor",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "ceil",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "round",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "trunc",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float",
    },
  ),
  (
    "pow",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Float", "Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float -> Float",
    },
  ),
  (
    "atan2",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Float", "Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float -> Float",
    },
  ),
  (
    "hypot",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Float", "Float"],
      resultHead = "Float",
      canonicalSignature = "v1:Float -> Float -> Float",
    },
  ),
  (
    "intBitsToFloat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Float",
      canonicalSignature = "v1:Int -> Float",
    },
  ),
  (
    "bytesToFloat64",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Array", "Int"],
      resultHead = "Float",
      canonicalSignature = "v1:Array Int -> Int -> Float",
    },
  ),
  (
    "floatToBytes64",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "Array",
      canonicalSignature = "v1:Float -> Array Int",
    },
  ),
  (
    "intToString",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "String",
      canonicalSignature = "v1:Int -> String",
    },
  ),
  (
    "floatToString",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Float"],
      resultHead = "String",
      canonicalSignature = "v1:Float -> String",
    },
  ),
  (
    "floatToFixed",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Float"],
      resultHead = "String",
      canonicalSignature = "v1:Int -> Float -> String",
    },
  ),
  (
    "debugStringLit",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "String",
      canonicalSignature = "v1:String -> String",
    },
  ),
  (
    "debugCharLit",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "String",
      canonicalSignature = "v1:Char -> String",
    },
  ),
  (
    "arrayLength",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Array"],
      resultHead = "Int",
      canonicalSignature = "v1:Array a -> Int",
    },
  ),
  (
    "arrayMake",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "a"],
      resultHead = "Array",
      canonicalSignature = "v1:Int -> a -> Array a",
    },
  ),
  (
    "arrayMakeWith",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", ""],
      resultHead = "Array",
      canonicalSignature = "v1:Int -> (Int -> <e> a) -> <e> Array a",
    },
  ),
  (
    "arrayGetUnsafe",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Array"],
      resultHead = "a",
      canonicalSignature = "v1:Int -> Array a -> a",
    },
  ),
  (
    "arraySetUnsafe",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Int", "a", "Array"],
      resultHead = "Unit",
      canonicalSignature = "v1:Int -> a -> Array a -> Unit",
    },
  ),
  (
    "arrayCopy",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Array"],
      resultHead = "Array",
      canonicalSignature = "v1:Array a -> Array a",
    },
  ),
  (
    "arrayBlit",
    CallableShape {
      writtenValueArity = 5,
      loweredCoreArity = 5,
      parameterHeads = ["Array", "Int", "Array", "Int", "Int"],
      resultHead = "Unit",
      canonicalSignature = "v1:Array a -> Int -> Array a -> Int -> Int -> Unit",
    },
  ),
  (
    "arrayFill",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["a", "Array"],
      resultHead = "Unit",
      canonicalSignature = "v1:a -> Array a -> Unit",
    },
  ),
  (
    "arrayFromList",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["List"],
      resultHead = "Array",
      canonicalSignature = "v1:List a -> Array a",
    },
  ),
  (
    "u8Truncate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "U8",
      canonicalSignature = "v1:Int -> U8",
    },
  ),
  (
    "u8ToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U8"],
      resultHead = "Int",
      canonicalSignature = "v1:U8 -> Int",
    },
  ),
  (
    "u16Truncate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "U16",
      canonicalSignature = "v1:Int -> U16",
    },
  ),
  (
    "u16ToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U16"],
      resultHead = "Int",
      canonicalSignature = "v1:U16 -> Int",
    },
  ),
  (
    "u32Truncate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "U32",
      canonicalSignature = "v1:Int -> U32",
    },
  ),
  (
    "u32ToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U32"],
      resultHead = "Int",
      canonicalSignature = "v1:U32 -> Int",
    },
  ),
  (
    "intBitAnd",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "intBitOr",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "intBitXor",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "intBitNot",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int",
    },
  ),
  (
    "intShiftLeft",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "intShiftRight",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> Int -> Int",
    },
  ),
  (
    "u64Truncate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "U64",
      canonicalSignature = "v1:Int -> U64",
    },
  ),
  (
    "u64TruncateToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U64"],
      resultHead = "Int",
      canonicalSignature = "v1:U64 -> Int",
    },
  ),
  (
    "u64BitAnd",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "U64"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> U64 -> U64",
    },
  ),
  (
    "u64BitOr",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "U64"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> U64 -> U64",
    },
  ),
  (
    "u64BitXor",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "U64"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> U64 -> U64",
    },
  ),
  (
    "u64ShiftLeft",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "Int"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> Int -> U64",
    },
  ),
  (
    "u64ShiftRight",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "Int"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> Int -> U64",
    },
  ),
  (
    "u64MulHigh",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["U64", "U64"],
      resultHead = "U64",
      canonicalSignature = "v1:U64 -> U64 -> U64",
    },
  ),
  (
    "i32Truncate",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "I32",
      canonicalSignature = "v1:Int -> I32",
    },
  ),
  (
    "i32ToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["I32"],
      resultHead = "Int",
      canonicalSignature = "v1:I32 -> Int",
    },
  ),
  (
    "i64FromBits",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["U64"],
      resultHead = "I64",
      canonicalSignature = "v1:U64 -> I64",
    },
  ),
  (
    "i64ToBits",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["I64"],
      resultHead = "U64",
      canonicalSignature = "v1:I64 -> U64",
    },
  ),
  (
    "byteBlockMake",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "ByteBlock",
      canonicalSignature = "v1:Int -> ByteBlock",
    },
  ),
  (
    "byteBlockLength",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ByteBlock"],
      resultHead = "Int",
      canonicalSignature = "v1:ByteBlock -> Int",
    },
  ),
  (
    "byteBlockGetUnsafe",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "ByteBlock"],
      resultHead = "Int",
      canonicalSignature = "v1:Int -> ByteBlock -> Int",
    },
  ),
  (
    "byteBlockSetUnsafe",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Int", "Int", "ByteBlock"],
      resultHead = "Unit",
      canonicalSignature = "v1:Int -> Int -> ByteBlock -> Unit",
    },
  ),
  (
    "byteBlockCopyUnsafe",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["Int", "ByteBlock"],
      resultHead = "ByteBlock",
      canonicalSignature = "v1:Int -> ByteBlock -> ByteBlock",
    },
  ),
  (
    "byteBlockBlit",
    CallableShape {
      writtenValueArity = 5,
      loweredCoreArity = 5,
      parameterHeads = ["ByteBlock", "Int", "ByteBlock", "Int", "Int"],
      resultHead = "Unit",
      canonicalSignature =
        "v1:ByteBlock -> Int -> ByteBlock -> Int -> Int -> Unit",
    },
  ),
  (
    "byteBlockFromIntArray",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Array"],
      resultHead = "ByteBlock",
      canonicalSignature = "v1:Array Int -> ByteBlock",
    },
  ),
  (
    "byteBlockToIntArray",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ByteBlock"],
      resultHead = "Array",
      canonicalSignature = "v1:ByteBlock -> Array Int",
    },
  ),
  (
    "byteBlockFromString",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "ByteBlock",
      canonicalSignature = "v1:String -> ByteBlock",
    },
  ),
  (
    "byteBlockToString",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ByteBlock"],
      resultHead = "String",
      canonicalSignature = "v1:ByteBlock -> String",
    },
  ),
  (
    "sha256Native",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ByteBlock"],
      resultHead = "ByteBlock",
      canonicalSignature = "v1:ByteBlock -> ByteBlock",
    },
  ),
  (
    "byteBlockWriteStdout",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["ByteBlock"],
      resultHead = "Unit",
      canonicalSignature = "v1:ByteBlock -> <Stdout> Unit",
    },
  ),
  (
    "stringToChars",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Array",
      canonicalSignature = "v1:String -> Array Char",
    },
  ),
  (
    "stringFromChars",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Array"],
      resultHead = "String",
      canonicalSignature = "v1:Array Char -> String",
    },
  ),
  (
    "stringToUtf8Bytes",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Array",
      canonicalSignature = "v1:String -> Array Int",
    },
  ),
  (
    "stringFromUtf8Bytes",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Array"],
      resultHead = "String",
      canonicalSignature = "v1:Array Int -> String",
    },
  ),
  (
    "charToStr",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "String",
      canonicalSignature = "v1:Char -> String",
    },
  ),
  (
    "charCode",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Int",
      canonicalSignature = "v1:Char -> Int",
    },
  ),
  (
    "charFromCode",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Int"],
      resultHead = "Option",
      canonicalSignature = "v1:Int -> Option Char",
    },
  ),
  (
    "stringLength",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Int",
      canonicalSignature = "v1:String -> Int",
    },
  ),
  (
    "stringByteLength",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Int",
      canonicalSignature = "v1:String -> Int",
    },
  ),
  (
    "stringSlice",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Int", "Int", "String"],
      resultHead = "String",
      canonicalSignature = "v1:Int -> Int -> String -> String",
    },
  ),
  (
    "stringCodepointAtByte",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "Int"],
      resultHead = "Int",
      canonicalSignature = "v1:String -> Int -> Int",
    },
  ),
  (
    "stringSliceBytes",
    CallableShape {
      writtenValueArity = 3,
      loweredCoreArity = 3,
      parameterHeads = ["Int", "Int", "String"],
      resultHead = "String",
      canonicalSignature = "v1:Int -> Int -> String -> String",
    },
  ),
  (
    "stringConcat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["List"],
      resultHead = "String",
      canonicalSignature = "v1:List String -> String",
    },
  ),
  (
    "stringIndexOf",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Option",
      canonicalSignature = "v1:String -> String -> Option Int",
    },
  ),
  (
    "stringStartsWith",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Bool",
      canonicalSignature = "v1:String -> String -> Bool",
    },
  ),
  (
    "stringEndsWith",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Bool",
      canonicalSignature = "v1:String -> String -> Bool",
    },
  ),
  (
    "stringCountOccurrences",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Int",
      canonicalSignature = "v1:String -> String -> Int",
    },
  ),
  (
    "stringLastIndexOf",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Option",
      canonicalSignature = "v1:String -> String -> Option Int",
    },
  ),
  (
    "stringToInt",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Option",
      canonicalSignature = "v1:String -> Option Int",
    },
  ),
  (
    "stringJoin",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "List"],
      resultHead = "String",
      canonicalSignature = "v1:String -> List String -> String",
    },
  ),
  (
    "stringReverse",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "String",
      canonicalSignature = "v1:String -> String",
    },
  ),
  (
    "stringCompare",
    CallableShape {
      writtenValueArity = 2,
      loweredCoreArity = 2,
      parameterHeads = ["String", "String"],
      resultHead = "Ordering",
      canonicalSignature = "v1:String -> String -> Ordering",
    },
  ),
  (
    "stringToFloat",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "Option",
      canonicalSignature = "v1:String -> Option Float",
    },
  ),
  (
    "charIsAlpha",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Bool",
      canonicalSignature = "v1:Char -> Bool",
    },
  ),
  (
    "charIsSpace",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Bool",
      canonicalSignature = "v1:Char -> Bool",
    },
  ),
  (
    "charIsUpper",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Bool",
      canonicalSignature = "v1:Char -> Bool",
    },
  ),
  (
    "charIsLower",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Bool",
      canonicalSignature = "v1:Char -> Bool",
    },
  ),
  (
    "charIsPunct",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Bool",
      canonicalSignature = "v1:Char -> Bool",
    },
  ),
  (
    "charToUpper",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Char",
      canonicalSignature = "v1:Char -> Char",
    },
  ),
  (
    "charToLower",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["Char"],
      resultHead = "Char",
      canonicalSignature = "v1:Char -> Char",
    },
  ),
  (
    "stringToUpper",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "String",
      canonicalSignature = "v1:String -> String",
    },
  ),
  (
    "stringToLower",
    CallableShape {
      writtenValueArity = 1,
      loweredCoreArity = 1,
      parameterHeads = ["String"],
      resultHead = "String",
      canonicalSignature = "v1:String -> String",
    },
  ),
]
# DESUGAR
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DTypeSig true "runtimeAbiRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape"))))
(DFunDef false "runtimeAbiRows" () (EListLit (ETuple (ELit (LString "putStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stdout> Unit")))))) (ETuple (ELit (LString "putStrLn")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stdout> Unit")))))) (ETuple (ELit (LString "ePutStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stderr> Unit")))))) (ETuple (ELit (LString "ePutStrLn")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stderr> Unit")))))) (ETuple (ELit (LString "flushStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdout> Unit")))))) (ETuple (ELit (LString "readLine")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> String")))))) (ETuple (ELit (LString "readLineOpt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> Option String")))))) (ETuple (ELit (LString "readAll")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> String")))))) (ETuple (ELit (LString "readExactly")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Stdin> Option String")))))) (ETuple (ELit (LString "Ref")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Ref"))) (fa "canonicalSignature" (ELit (LString "v1:a -> Ref a")))))) (ETuple (ELit (LString "setRef")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Ref")) (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Ref a -> a -> Unit")))))) (ETuple (ELit (LString "readFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String String")))))) (ETuple (ELit (LString "readFileBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (Array Int)")))))) (ETuple (ELit (LString "writeFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "writeFileBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> Array Int -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "writeFileMode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> Int -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "appendFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "fileExists")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Bool")))))) (ETuple (ELit (LString "fileMode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String Int")))))) (ETuple (ELit (LString "canonicalizePath")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> String")))))) (ETuple (ELit (LString "listDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (List String)")))))) (ETuple (ELit (LString "makeDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "removeFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "rename")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(src : String) -> (dst : String) -> <FileWrite src, FileWrite dst> Result String Unit")))))) (ETuple (ELit (LString "fsync")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "removeDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "statFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (Int, Bool, Bool, Float)")))))) (ETuple (ELit (LString "args")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "List"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> List String")))))) (ETuple (ELit (LString "getEnv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:(name : String) -> <Env name> Option String")))))) (ETuple (ELit (LString "executablePath")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Env> String")))))) (ETuple (ELit (LString "buildFingerprint")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "buildCommit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "buildDate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "runCommand")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(program : String) -> List String -> <Exec program> Result String (Int, String, String)")))))) (ETuple (ELit (LString "runCommandBatch")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "List"))) (fa "canonicalSignature" (ELit (LString "v1:(program : String) -> Int -> List (List String) -> <Exec program> List (Result String (Int, String, String))")))))) (ETuple (ELit (LString "exit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Unit")))))) (ETuple (ELit (LString "panic")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:String -> a")))))) (ETuple (ELit (LString "indexError")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:String -> a")))))) (ETuple (ELit (LString "indexErrorAt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a")))))) (ETuple (ELit (LString "indexErrorAtSite")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> a")))))) (ETuple (ELit (LString "panicAt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> String -> a")))))) (ETuple (ELit (LString "sliceError")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> a")))))) (ETuple (ELit (LString "stashRunStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Unit")))))) (ETuple (ELit (LString "enableRunStdoutFlush")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> Unit")))))) (ETuple (ELit (LString "__fallthrough__")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> a")))))) (ETuple (ELit (LString "assertSnapshot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> <IO> Unit")))))) (ETuple (ELit (LString "netResolve")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> <Net host> Result String (List String)")))))) (ETuple (ELit (LString "netTcpConnect")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (Socket host)")))))) (ETuple (ELit (LString "netTcpListen")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (ListenSocket host)")))))) (ETuple (ELit (LString "netListenPort")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String Int")))))) (ETuple (ELit (LString "netTcpAccept")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String (Socket a)")))))) (ETuple (ELit (LString "netSend")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netSendFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netRecv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Array Int)")))))) (ETuple (ELit (LString "netShutdown")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netClose")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netCloseListener")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String Unit")))))) (ETuple (ELit (LString "netSetTimeout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "socketFd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int")))))) (ETuple (ELit (LString "listenSocketFd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> Int")))))) (ETuple (ELit (LString "pdsSignalStart")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Signal> Result String Int")))))) (ETuple (ELit (LString "pdsSignalRequested")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Signal> Bool")))))) (ETuple (ELit (LString "ioPoll")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> Array Int -> Int -> <Clock> Result String (Array Int)")))))) (ETuple (ELit (LString "netSetNonblock")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Bool -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netSetNonblockListener")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")) (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> Bool -> <Net a> Result String Unit")))))) (ETuple (ELit (LString "netTryAccept")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String (Option (Socket a))")))))) (ETuple (ELit (LString "netConnectStart")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (Socket host)")))))) (ETuple (ELit (LString "netConnectCheck")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> <Net h> Result String (Option Unit)")))))) (ETuple (ELit (LString "netTryRecv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Option (Array Int))")))))) (ETuple (ELit (LString "netTryRecvBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Option ByteBlock)")))))) (ETuple (ELit (LString "netTrySend")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "netTrySendFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "netSendBytesFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 4))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netTrySendBytesFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 4))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "wallTimeSec")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Clock> Float")))))) (ETuple (ELit (LString "monotonicSec")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Clock> Float")))))) (ETuple (ELit (LString "sleepMs")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Clock> Unit")))))) (ETuple (ELit (LString "fetchText")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(url : String) -> <Net url> Result String String")))))) (ETuple (ELit (LString "allocBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <IO> Float")))))) (ETuple (ELit (LString "randomInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> <Rand> Int")))))) (ETuple (ELit (LString "randomBool")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Bool")))))) (ETuple (ELit (LString "randomFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Float")))))) (ETuple (ELit (LString "randomChar")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Char")))))) (ETuple (ELit (LString "setSeed")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Rand> Unit")))))) (ETuple (ELit (LString "randomState")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> U64")))))) (ETuple (ELit (LString "restoreRandomState")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> <Rand> Unit")))))) (ETuple (ELit (LString "osEntropyBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Rand> Array Int")))))) (ETuple (ELit (LString "hashInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "hashFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Int")))))) (ETuple (ELit (LString "hashString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "hashChar")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Int")))))) (ETuple (ELit (LString "hashBool")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Bool -> Int")))))) (ETuple (ELit (LString "pi")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float")))))) (ETuple (ELit (LString "e")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float")))))) (ETuple (ELit (LString "intMinBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int")))))) (ETuple (ELit (LString "intMaxBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int")))))) (ETuple (ELit (LString "charMinBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char")))))) (ETuple (ELit (LString "charMaxBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char")))))) (ETuple (ELit (LString "intToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float")))))) (ETuple (ELit (LString "floatToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Int")))))) (ETuple (ELit (LString "floatRem")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "bitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "shiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "shiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitNot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "sqrt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cbrt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "exp")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log2")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log10")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "sin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cos")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "tan")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "asin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "acos")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "atan")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "sinh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cosh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "tanh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "floor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "ceil")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "round")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "trunc")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "pow")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "atan2")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "hypot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "intBitsToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float")))))) (ETuple (ELit (LString "bytesToFloat64")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> Int -> Float")))))) (ETuple (ELit (LString "floatToBytes64")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Array Int")))))) (ETuple (ELit (LString "intToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> String")))))) (ETuple (ELit (LString "floatToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> String")))))) (ETuple (ELit (LString "floatToFixed")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float -> String")))))) (ETuple (ELit (LString "debugStringLit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "debugCharLit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> String")))))) (ETuple (ELit (LString "arrayLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Int")))))) (ETuple (ELit (LString "arrayMake")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a -> Array a")))))) (ETuple (ELit (LString "arrayMakeWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> (Int -> <e> a) -> <e> Array a")))))) (ETuple (ELit (LString "arrayGetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Array a -> a")))))) (ETuple (ELit (LString "arraySetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "a")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a -> Array a -> Unit")))))) (ETuple (ELit (LString "arrayCopy")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Array a")))))) (ETuple (ELit (LString "arrayBlit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 5))) (fa "loweredCoreArity" (ELit (LInt 5))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Int")) (ELit (LString "Array")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Int -> Array a -> Int -> Int -> Unit")))))) (ETuple (ELit (LString "arrayFill")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "a")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:a -> Array a -> Unit")))))) (ETuple (ELit (LString "arrayFromList")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "List")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:List a -> Array a")))))) (ETuple (ELit (LString "u8Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U8"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U8")))))) (ETuple (ELit (LString "u8ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U8")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U8 -> Int")))))) (ETuple (ELit (LString "u16Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U16"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U16")))))) (ETuple (ELit (LString "u16ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U16")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U16 -> Int")))))) (ETuple (ELit (LString "u32Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U32"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U32")))))) (ETuple (ELit (LString "u32ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U32")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U32 -> Int")))))) (ETuple (ELit (LString "intBitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitNot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "intShiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intShiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "u64Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U64")))))) (ETuple (ELit (LString "u64TruncateToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int")))))) (ETuple (ELit (LString "u64BitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64BitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64BitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64ShiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int -> U64")))))) (ETuple (ELit (LString "u64ShiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int -> U64")))))) (ETuple (ELit (LString "u64MulHigh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "i32Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "I32"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> I32")))))) (ETuple (ELit (LString "i32ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "I32")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:I32 -> Int")))))) (ETuple (ELit (LString "i64FromBits")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "I64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> I64")))))) (ETuple (ELit (LString "i64ToBits")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "I64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:I64 -> U64")))))) (ETuple (ELit (LString "byteBlockMake")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Int")))))) (ETuple (ELit (LString "byteBlockGetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock -> Int")))))) (ETuple (ELit (LString "byteBlockSetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> ByteBlock -> Unit")))))) (ETuple (ELit (LString "byteBlockCopyUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockBlit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 5))) (fa "loweredCoreArity" (ELit (LInt 5))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Int -> ByteBlock -> Int -> Int -> Unit")))))) (ETuple (ELit (LString "byteBlockFromIntArray")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockToIntArray")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Array Int")))))) (ETuple (ELit (LString "byteBlockFromString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:String -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> String")))))) (ETuple (ELit (LString "sha256Native")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockWriteStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> <Stdout> Unit")))))) (ETuple (ELit (LString "stringToChars")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Array Char")))))) (ETuple (ELit (LString "stringFromChars")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Array Char -> String")))))) (ETuple (ELit (LString "stringToUtf8Bytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Array Int")))))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> String")))))) (ETuple (ELit (LString "charToStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> String")))))) (ETuple (ELit (LString "charCode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Int")))))) (ETuple (ELit (LString "charFromCode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Option Char")))))) (ETuple (ELit (LString "stringLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "stringByteLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "stringSlice")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> String -> String")))))) (ETuple (ELit (LString "stringCodepointAtByte")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int -> Int")))))) (ETuple (ELit (LString "stringSliceBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> String -> String")))))) (ETuple (ELit (LString "stringConcat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "List")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:List String -> String")))))) (ETuple (ELit (LString "stringIndexOf")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Option Int")))))) (ETuple (ELit (LString "stringStartsWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Bool")))))) (ETuple (ELit (LString "stringEndsWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Bool")))))) (ETuple (ELit (LString "stringCountOccurrences")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Int")))))) (ETuple (ELit (LString "stringLastIndexOf")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Option Int")))))) (ETuple (ELit (LString "stringToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Option Int")))))) (ETuple (ELit (LString "stringJoin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> List String -> String")))))) (ETuple (ELit (LString "stringReverse")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "stringCompare")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Ordering"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Ordering")))))) (ETuple (ELit (LString "stringToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Option Float")))))) (ETuple (ELit (LString "charIsAlpha")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsSpace")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsPunct")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charToUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Char")))))) (ETuple (ELit (LString "charToLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Char")))))) (ETuple (ELit (LString "stringToUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "stringToLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String"))))))))
# MARK
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DTypeSig true "runtimeAbiRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape"))))
(DFunDef false "runtimeAbiRows" () (EListLit (ETuple (ELit (LString "putStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stdout> Unit")))))) (ETuple (ELit (LString "putStrLn")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stdout> Unit")))))) (ETuple (ELit (LString "ePutStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stderr> Unit")))))) (ETuple (ELit (LString "ePutStrLn")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> <Stderr> Unit")))))) (ETuple (ELit (LString "flushStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdout> Unit")))))) (ETuple (ELit (LString "readLine")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> String")))))) (ETuple (ELit (LString "readLineOpt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> Option String")))))) (ETuple (ELit (LString "readAll")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Stdin> String")))))) (ETuple (ELit (LString "readExactly")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Stdin> Option String")))))) (ETuple (ELit (LString "Ref")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Ref"))) (fa "canonicalSignature" (ELit (LString "v1:a -> Ref a")))))) (ETuple (ELit (LString "setRef")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Ref")) (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Ref a -> a -> Unit")))))) (ETuple (ELit (LString "readFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String String")))))) (ETuple (ELit (LString "readFileBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (Array Int)")))))) (ETuple (ELit (LString "writeFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "writeFileBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> Array Int -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "writeFileMode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> Int -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "appendFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> String -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "fileExists")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Bool")))))) (ETuple (ELit (LString "fileMode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String Int")))))) (ETuple (ELit (LString "canonicalizePath")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> String")))))) (ETuple (ELit (LString "listDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (List String)")))))) (ETuple (ELit (LString "makeDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "removeFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "rename")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(src : String) -> (dst : String) -> <FileWrite src, FileWrite dst> Result String Unit")))))) (ETuple (ELit (LString "fsync")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "removeDir")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileWrite path> Result String Unit")))))) (ETuple (ELit (LString "statFile")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(path : String) -> <FileRead path> Result String (Int, Bool, Bool, Float)")))))) (ETuple (ELit (LString "args")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "List"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> List String")))))) (ETuple (ELit (LString "getEnv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:(name : String) -> <Env name> Option String")))))) (ETuple (ELit (LString "executablePath")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Env> String")))))) (ETuple (ELit (LString "buildFingerprint")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "buildCommit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "buildDate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> String")))))) (ETuple (ELit (LString "runCommand")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(program : String) -> List String -> <Exec program> Result String (Int, String, String)")))))) (ETuple (ELit (LString "runCommandBatch")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "List"))) (fa "canonicalSignature" (ELit (LString "v1:(program : String) -> Int -> List (List String) -> <Exec program> List (Result String (Int, String, String))")))))) (ETuple (ELit (LString "exit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Unit")))))) (ETuple (ELit (LString "panic")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:String -> a")))))) (ETuple (ELit (LString "indexError")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:String -> a")))))) (ETuple (ELit (LString "indexErrorAt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a")))))) (ETuple (ELit (LString "indexErrorAtSite")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> a")))))) (ETuple (ELit (LString "panicAt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> String -> a")))))) (ETuple (ELit (LString "sliceError")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> a")))))) (ETuple (ELit (LString "stashRunStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Unit")))))) (ETuple (ELit (LString "enableRunStdoutFlush")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> Unit")))))) (ETuple (ELit (LString "__fallthrough__")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> a")))))) (ETuple (ELit (LString "assertSnapshot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> <IO> Unit")))))) (ETuple (ELit (LString "netResolve")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> <Net host> Result String (List String)")))))) (ETuple (ELit (LString "netTcpConnect")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (Socket host)")))))) (ETuple (ELit (LString "netTcpListen")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (ListenSocket host)")))))) (ETuple (ELit (LString "netListenPort")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String Int")))))) (ETuple (ELit (LString "netTcpAccept")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String (Socket a)")))))) (ETuple (ELit (LString "netSend")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netSendFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netRecv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Array Int)")))))) (ETuple (ELit (LString "netShutdown")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netClose")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netCloseListener")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String Unit")))))) (ETuple (ELit (LString "netSetTimeout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "socketFd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int")))))) (ETuple (ELit (LString "listenSocketFd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> Int")))))) (ETuple (ELit (LString "pdsSignalStart")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Signal> Result String Int")))))) (ETuple (ELit (LString "pdsSignalRequested")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Signal> Bool")))))) (ETuple (ELit (LString "ioPoll")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> Array Int -> Int -> <Clock> Result String (Array Int)")))))) (ETuple (ELit (LString "netSetNonblock")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Bool -> <Net h> Result String Unit")))))) (ETuple (ELit (LString "netSetNonblockListener")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")) (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> Bool -> <Net a> Result String Unit")))))) (ETuple (ELit (LString "netTryAccept")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ListenSocket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:ListenSocket a -> <Net a> Result String (Option (Socket a))")))))) (ETuple (ELit (LString "netConnectStart")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(host : String) -> Int -> <Net host> Result String (Socket host)")))))) (ETuple (ELit (LString "netConnectCheck")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> <Net h> Result String (Option Unit)")))))) (ETuple (ELit (LString "netTryRecv")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Option (Array Int))")))))) (ETuple (ELit (LString "netTryRecvBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Int -> <Net h> Result String (Option ByteBlock)")))))) (ETuple (ELit (LString "netTrySend")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "netTrySendFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> Array Int -> Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "netSendBytesFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 4))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String Int")))))) (ETuple (ELit (LString "netTrySendBytesFrom")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 4))) (fa "loweredCoreArity" (ELit (LInt 4))) (fa "parameterHeads" (EListLit (ELit (LString "Socket")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:Socket h -> ByteBlock -> Int -> Int -> <Net h> Result String (Option Int)")))))) (ETuple (ELit (LString "wallTimeSec")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Clock> Float")))))) (ETuple (ELit (LString "monotonicSec")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Clock> Float")))))) (ETuple (ELit (LString "sleepMs")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Clock> Unit")))))) (ETuple (ELit (LString "fetchText")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Result"))) (fa "canonicalSignature" (ELit (LString "v1:(url : String) -> <Net url> Result String String")))))) (ETuple (ELit (LString "allocBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <IO> Float")))))) (ETuple (ELit (LString "randomInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> <Rand> Int")))))) (ETuple (ELit (LString "randomBool")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Bool")))))) (ETuple (ELit (LString "randomFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Float")))))) (ETuple (ELit (LString "randomChar")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> Char")))))) (ETuple (ELit (LString "setSeed")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Rand> Unit")))))) (ETuple (ELit (LString "randomState")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Unit")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:Unit -> <Rand> U64")))))) (ETuple (ELit (LString "restoreRandomState")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> <Rand> Unit")))))) (ETuple (ELit (LString "osEntropyBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> <Rand> Array Int")))))) (ETuple (ELit (LString "hashInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "hashFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Int")))))) (ETuple (ELit (LString "hashString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "hashChar")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Int")))))) (ETuple (ELit (LString "hashBool")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Bool")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Bool -> Int")))))) (ETuple (ELit (LString "pi")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float")))))) (ETuple (ELit (LString "e")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float")))))) (ETuple (ELit (LString "intMinBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int")))))) (ETuple (ELit (LString "intMaxBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int")))))) (ETuple (ELit (LString "charMinBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char")))))) (ETuple (ELit (LString "charMaxBound")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 0))) (fa "loweredCoreArity" (ELit (LInt 0))) (fa "parameterHeads" (EListLit)) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char")))))) (ETuple (ELit (LString "intToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float")))))) (ETuple (ELit (LString "floatToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Int")))))) (ETuple (ELit (LString "floatRem")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "bitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "shiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "shiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "bitNot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "sqrt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cbrt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "exp")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log2")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "log10")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "sin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cos")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "tan")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "asin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "acos")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "atan")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "sinh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "cosh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "tanh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "floor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "ceil")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "round")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "trunc")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float")))))) (ETuple (ELit (LString "pow")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "atan2")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "hypot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Float")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Float -> Float")))))) (ETuple (ELit (LString "intBitsToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float")))))) (ETuple (ELit (LString "bytesToFloat64")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Float"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> Int -> Float")))))) (ETuple (ELit (LString "floatToBytes64")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> Array Int")))))) (ETuple (ELit (LString "intToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> String")))))) (ETuple (ELit (LString "floatToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Float -> String")))))) (ETuple (ELit (LString "floatToFixed")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Float")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Float -> String")))))) (ETuple (ELit (LString "debugStringLit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "debugCharLit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> String")))))) (ETuple (ELit (LString "arrayLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Int")))))) (ETuple (ELit (LString "arrayMake")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "a")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a -> Array a")))))) (ETuple (ELit (LString "arrayMakeWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> (Int -> <e> a) -> <e> Array a")))))) (ETuple (ELit (LString "arrayGetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "a"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Array a -> a")))))) (ETuple (ELit (LString "arraySetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "a")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> a -> Array a -> Unit")))))) (ETuple (ELit (LString "arrayCopy")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Array a")))))) (ETuple (ELit (LString "arrayBlit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 5))) (fa "loweredCoreArity" (ELit (LInt 5))) (fa "parameterHeads" (EListLit (ELit (LString "Array")) (ELit (LString "Int")) (ELit (LString "Array")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Array a -> Int -> Array a -> Int -> Int -> Unit")))))) (ETuple (ELit (LString "arrayFill")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "a")) (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:a -> Array a -> Unit")))))) (ETuple (ELit (LString "arrayFromList")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "List")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:List a -> Array a")))))) (ETuple (ELit (LString "u8Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U8"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U8")))))) (ETuple (ELit (LString "u8ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U8")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U8 -> Int")))))) (ETuple (ELit (LString "u16Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U16"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U16")))))) (ETuple (ELit (LString "u16ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U16")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U16 -> Int")))))) (ETuple (ELit (LString "u32Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U32"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U32")))))) (ETuple (ELit (LString "u32ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U32")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U32 -> Int")))))) (ETuple (ELit (LString "intBitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intBitNot")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int")))))) (ETuple (ELit (LString "intShiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "intShiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> Int")))))) (ETuple (ELit (LString "u64Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> U64")))))) (ETuple (ELit (LString "u64TruncateToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int")))))) (ETuple (ELit (LString "u64BitAnd")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64BitOr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64BitXor")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "u64ShiftLeft")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int -> U64")))))) (ETuple (ELit (LString "u64ShiftRight")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> Int -> U64")))))) (ETuple (ELit (LString "u64MulHigh")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "U64")) (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> U64 -> U64")))))) (ETuple (ELit (LString "i32Truncate")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "I32"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> I32")))))) (ETuple (ELit (LString "i32ToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "I32")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:I32 -> Int")))))) (ETuple (ELit (LString "i64FromBits")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "U64")))) (fa "resultHead" (ELit (LString "I64"))) (fa "canonicalSignature" (ELit (LString "v1:U64 -> I64")))))) (ETuple (ELit (LString "i64ToBits")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "I64")))) (fa "resultHead" (ELit (LString "U64"))) (fa "canonicalSignature" (ELit (LString "v1:I64 -> U64")))))) (ETuple (ELit (LString "byteBlockMake")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Int")))))) (ETuple (ELit (LString "byteBlockGetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock -> Int")))))) (ETuple (ELit (LString "byteBlockSetUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> ByteBlock -> Unit")))))) (ETuple (ELit (LString "byteBlockCopyUnsafe")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> ByteBlock -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockBlit")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 5))) (fa "loweredCoreArity" (ELit (LInt 5))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "ByteBlock")) (ELit (LString "Int")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Int -> ByteBlock -> Int -> Int -> Unit")))))) (ETuple (ELit (LString "byteBlockFromIntArray")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockToIntArray")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> Array Int")))))) (ETuple (ELit (LString "byteBlockFromString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:String -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockToString")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> String")))))) (ETuple (ELit (LString "sha256Native")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "ByteBlock"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> ByteBlock")))))) (ETuple (ELit (LString "byteBlockWriteStdout")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "ByteBlock")))) (fa "resultHead" (ELit (LString "Unit"))) (fa "canonicalSignature" (ELit (LString "v1:ByteBlock -> <Stdout> Unit")))))) (ETuple (ELit (LString "stringToChars")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Array Char")))))) (ETuple (ELit (LString "stringFromChars")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Array Char -> String")))))) (ETuple (ELit (LString "stringToUtf8Bytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Array"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Array Int")))))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Array")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Array Int -> String")))))) (ETuple (ELit (LString "charToStr")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> String")))))) (ETuple (ELit (LString "charCode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Int")))))) (ETuple (ELit (LString "charFromCode")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Option Char")))))) (ETuple (ELit (LString "stringLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "stringByteLength")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int")))))) (ETuple (ELit (LString "stringSlice")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> String -> String")))))) (ETuple (ELit (LString "stringCodepointAtByte")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "Int")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Int -> Int")))))) (ETuple (ELit (LString "stringSliceBytes")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 3))) (fa "loweredCoreArity" (ELit (LInt 3))) (fa "parameterHeads" (EListLit (ELit (LString "Int")) (ELit (LString "Int")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:Int -> Int -> String -> String")))))) (ETuple (ELit (LString "stringConcat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "List")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:List String -> String")))))) (ETuple (ELit (LString "stringIndexOf")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Option Int")))))) (ETuple (ELit (LString "stringStartsWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Bool")))))) (ETuple (ELit (LString "stringEndsWith")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Bool")))))) (ETuple (ELit (LString "stringCountOccurrences")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Int"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Int")))))) (ETuple (ELit (LString "stringLastIndexOf")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Option Int")))))) (ETuple (ELit (LString "stringToInt")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Option Int")))))) (ETuple (ELit (LString "stringJoin")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "List")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> List String -> String")))))) (ETuple (ELit (LString "stringReverse")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "stringCompare")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 2))) (fa "loweredCoreArity" (ELit (LInt 2))) (fa "parameterHeads" (EListLit (ELit (LString "String")) (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Ordering"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String -> Ordering")))))) (ETuple (ELit (LString "stringToFloat")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "Option"))) (fa "canonicalSignature" (ELit (LString "v1:String -> Option Float")))))) (ETuple (ELit (LString "charIsAlpha")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsSpace")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charIsPunct")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Bool"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Bool")))))) (ETuple (ELit (LString "charToUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Char")))))) (ETuple (ELit (LString "charToLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "Char")))) (fa "resultHead" (ELit (LString "Char"))) (fa "canonicalSignature" (ELit (LString "v1:Char -> Char")))))) (ETuple (ELit (LString "stringToUpper")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String")))))) (ETuple (ELit (LString "stringToLower")) (ERecordCreate "CallableShape" ((fa "writtenValueArity" (ELit (LInt 1))) (fa "loweredCoreArity" (ELit (LInt 1))) (fa "parameterHeads" (EListLit (ELit (LString "String")))) (fa "resultHead" (ELit (LString "String"))) (fa "canonicalSignature" (ELit (LString "v1:String -> String"))))))))
