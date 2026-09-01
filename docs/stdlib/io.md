# io

io.mdk — files, standard streams, environment, and process I/O.

See STDLIB.md (Module 7) for the plan.

The irreducible host primitives are `extern`s in stdlib/runtime.mdk, so they
are **global** (no import needed): `readFile`/`writeFile`/`appendFile`,
`readLine`/`readLineOpt`/`readAll`, `args`, `getEnv`, `fileExists`, `listDir`,
`exit`, `putStr`/`putStrLn` (and the prelude's `print`/`println`), and the
stderr pair `ePutStr`/`ePutStrLn`. This module adds the ergonomic layer on
top — `Display`-based stderr output, line-oriented file reading, and an
`Option`-smoothing environment helper.

Conventions: file ops return `Result String _` with the host error message in
`Err`; `getEnv` returns `Option`. There is no IO monad — an action runs when
it is evaluated, so you can `match readFile path` directly.

## `eprint`

```
eprint : a -> <IO> Unit
```

Write a value to stderr (no trailing newline), rendered via `Display` —
the stderr analog of the prelude's `print`.

## `eprintln`

```
eprintln : a -> <IO> Unit
```

Write a value to stderr followed by a newline — the stderr analog of
`println`. Use for diagnostics and errors so they don't pollute stdout.

## `inspect`

```
inspect : a -> <IO> Unit
```

Print a value via `Debug` followed by a newline — the `Debug`-rendering
analog of `println`.  Unlike `println` (which uses `Display` and is
user-facing), `inspect` produces round-trippable output: strings and chars
are quoted, ADTs print with constructor names and field values.  Handy for
tracing intermediate values without a custom `Display` impl.

## `stripCR`

```
stripCR : String -> String
```

Line splitting is done here over the global `string*` kernel externs (in
runtime.mdk) rather than `import string.{lines}`.  string.mdk is importable
as of Phase 117, but `string.lines` deliberately *keeps* the final empty line
a trailing newline produces, whereas readLines drops it — so this stays a
local helper.  Splits on `\n`, dropping a trailing `\r` (so CRLF files work)
and the final empty line a trailing newline would otherwise produce.

## `readLines`

```
readLines : String -> <IO> Result String (List String)
```

Read a file and split it into lines, or `Err` with the host message on a
read failure. The trailing newline does not produce a final empty line.

## `getEnvOr`

```
getEnvOr : String -> String -> <IO> String
```

An environment variable's value, or `fallback` when it is unset.

