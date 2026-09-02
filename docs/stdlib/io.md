# io

## `eprint`

```
eprint : Display a => a -> <IO> Unit
```

Write a value to stderr (no trailing newline), rendered via `Display` —
the stderr analog of the prelude's `print`.

## `eprintln`

```
eprintln : Display a => a -> <IO> Unit
```

Write a value to stderr followed by a newline — the stderr analog of
`println`. Use for diagnostics and errors so they don't pollute stdout.

## `inspect`

```
inspect : Debug a => a -> <IO> Unit
```

Print a value via `Debug` followed by a newline — the `Debug`-rendering
analog of `println`.  Unlike `println` (which uses `Display` and is
user-facing), `inspect` produces round-trippable output: strings and chars
are quoted, ADTs print with constructor names and field values.  Handy for
tracing intermediate values without a custom `Display` impl.

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

