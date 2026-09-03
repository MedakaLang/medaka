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
```

Writes a value to standard error with no trailing newline.

The value is rendered with `display`, like `print`.

### `eprintln`

```
eprintln : Display a => a -> <IO> Unit
```

Writes a value to standard error, followed by a newline.

The value is rendered with `display`, like `println`. Use it for
diagnostics and errors so they do not mix with standard output.

## Debug output

### `inspect`

```
inspect : Debug a => a -> <IO> Unit
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
```

The lines of a file, or `Err` with the host's message when the file
cannot be read.

Lines are split on `\n`, with a `\r` before it removed. A trailing
newline does not produce a final empty line.

## Commands

### `runCommandOk`

```
runCommandOk : String -> List String -> <Exec _> Result String (String, String)
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
runVerb : String -> List String -> <Exec _> Result String (Int, String, String)
```

Runs a program with arguments and waits for it, keeping the exit code,
stdout, and stderr as three distinct fields instead of folding a nonzero
exit into an `Err` the way `runCommandOk` does.

Only a spawn failure (the program could not be started) is `Err`, with
the host's message. A nonzero exit is still `Ok`: a caller asserting on
failure output needs the exit code and stderr in hand, not conflated
into a rejected `Result` or silently dropped the way comparing stdout
alone would drop it.

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
```

The value of the environment variable `name`, or `fallback` when it is
unset.

