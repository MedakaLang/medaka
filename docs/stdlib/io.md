# io

Output to standard error, debug printing, and helpers for files and
the environment.

The primitive operations are in scope without an import: `readFile`,
`writeFile`, `appendFile`, `readLine`, `readLineOpt`, `readAll`, `args`,
`getEnv`, `fileExists`, `listDir`, `exit`, `putStr`, `putStrLn`,
`ePutStr`, and `ePutStrLn`, plus `print` and `println` from the prelude.
This module adds the convenience layer on top of them.

File operations return `Result String a`, with the host's error message
in `Err`. There is no IO monad: an action runs when it is evaluated, so
`match readFile path` works directly.

## Standard error

### `eprint`

```
eprint : Display a => a -> <IO> Unit
eprint x
```

Writes a value to standard error with no trailing newline.

The value is rendered with `display`, like `print`.

### `eprintln`

```
eprintln : Display a => a -> <IO> Unit
eprintln x
```

Writes a value to standard error, followed by a newline.

The value is rendered with `display`, like `println`. Use it for
diagnostics and errors so they do not mix with standard output.

## Debug output

### `inspect`

```
inspect : Debug a => a -> <IO> Unit
inspect x
```

Writes a value to standard output in its `debug` rendering, followed by
a newline.

Unlike `println`, strings and characters are quoted and constructors are
shown by name, so the output reads as Medaka source. Use it to trace
values without writing a `Display` instance.

## Files

### `readLines`

```
readLines : String -> <IO> Result String (List String)
readLines path
```

The lines of a file, or `Err` with the host's message when the file
cannot be read.

Lines are split on `\n`, with a `\r` before it removed. A trailing
newline does not produce a final empty line.

### `ownerOnlyMode`

```
ownerOnlyMode : Int
```

The permission bits of a file only its owner may read or write:
`rw-------`, `0600` as the chmod command spells it.

`writeFilePrivate` writes at this mode, and `isPrivateMode` accepts it.

### `isPrivateMode`

```
isPrivateMode : Int -> Bool
isPrivateMode mode
```

Whether permission bits keep a file to its owner, with no group or
other bit set.

A secret at any wider mode is readable by another account on the same
host, so a program that reads one should refuse it. `fileMode` reads a
path's bits.

```medaka
> isPrivateMode ownerOnlyMode
True
> isPrivateMode 420
False
> isPrivateMode 448
True
```

### `writeFilePrivate`

```
writeFilePrivate : (path : String) -> String -> <FileWrite path> Result String Unit
writeFilePrivate path content
```

Writes a string to a file that only its owner may read or write, at
`ownerOnlyMode`.

The contents never exist at a wider mode: an existing file at a wider one
is narrowed before they are written. Use it for a secret.

## Commands

### `runCommandOk`

```
runCommandOk : (cmd : String) -> List String -> <Exec cmd> Result String (String, String)
runCommandOk cmd args
```

Runs a program with arguments and waits for it, folding a spawn
failure and a nonzero exit into one `Err`.

`Ok` carries the captured stdout and stderr on a zero exit. `Err` names
the command and carries the host's message on a spawn failure, or the
exit code and captured stderr on a nonzero exit.

```medaka
> runCommandOk "true" []
Ok ("", "")
```

### `runVerb`

```
runVerb : (cmd : String) -> List String -> <Exec cmd> Result String (Int, String, String)
runVerb cmd args
```

Runs a program with arguments and waits for it, returning the exit
code, stdout, and stderr.

Only a failure to start the program is `Err`, with the host's message. A
nonzero exit is still `Ok`, so a caller can assert on the exit code and
stderr of a failing run. `runCommandOk` folds a nonzero exit into `Err`
instead.

```medaka
> runVerb "true" []
Ok (0, "", "")
> runVerb "sh" ["-c", "printf err >&2; exit 3"]
Ok (3, "", "err")
```

## Environment

### `getEnvOr`

```
getEnvOr : String -> String -> <IO> String
getEnvOr name fallback
```

The value of the environment variable `name`, or `fallback` when it is
unset.

