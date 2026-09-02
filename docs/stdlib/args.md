# args

A command-line argument parser.

Describe a command's flags as a value, an `ArgSpec` built with `spec`
and the flag constructors (`switch`, `value`, `oneOf`, `intValue`), then
`parseArgs` turns an argument list into an `Args` or a finished error
sentence. Because the specification is a value, the help text, the
`(known: ...)` list in an error, and the parser itself all come from the
same source and cannot disagree.

A flag with a value accepts both `--flag v` and `--flag=v`. Every name
in a flag's `names` list is accepted; the first is the canonical name
the query functions use.

## Specifications

### `Arity`

```
data Arity
  = Switch
  | Value String
  | ValueList String
  | OneOf (List String) String
  | IntValue String
```

What a flag does with the token after it.

`Switch` takes no value. The others take one, and carry the name shown
for it in help, such as `PATH` or `N`. `OneOf` also carries the set the
value must belong to; `IntValue` requires the value to be an integer;
`ValueList` is a comma-separated list, shown in help as `--flag=<M>` and
split by the caller.

Instances: `Eq`, `Debug`

### `Visibility`

```
data Visibility
  = Public
  | Internal
```

Whether a flag appears in `helpBlockOf`. Both kinds appear in
`rosterOf` and are parsed.

Instances: `Eq`, `Debug`

### `Unknown`

```
data Unknown
  = RejectUnknown
  | CollectUnknown
```

What happens to a flag-shaped token no `FlagSpec` claims.

`RejectUnknown` makes it an error. `CollectUnknown` records it in
`given`, taking the next token as its value, for a command whose flags
are not known in advance.

Instances: `Eq`, `Debug`

### `Trailing`

```
data Trailing
  = TrailingReject
  | TrailingRaw
  | TrailingAfterSeparator
```

How the command treats arguments after its own.

`TrailingReject` means there are none, so `--` is an ordinary unknown
flag. `TrailingRaw` ends flag scanning at the first positional and
leaves everything after it, `--` included, in `rest`.
`TrailingAfterSeparator` consumes the first `--` and puts everything
after it in `rest`.

Instances: `Eq`, `Debug`

### `FlagSpec`

```
data FlagSpec
  = FlagSpec { names : List String, arity : Arity, summary : String, visibility : Visibility }
```

One flag and every spelling it answers to.

`names` holds complete tokens with their dashes, such as
`["--write", "-w"]`. The first is the canonical name: the key recorded
in `Args.given` and queried by `flag` and `flagValue`, whichever
spelling was typed.

Instances: `Eq`, `Debug`

### `ArgSpec`

```
data ArgSpec
  = ArgSpec { verb : String, flags : List FlagSpec, trailing : Trailing, unknown : Unknown, strictDash : Bool }
```

A command's whole argument vocabulary.

`strictDash` controls an undeclared single-dash token such as `-x`.
When `False`, the default, it is a positional, so a file name starting
with `-` still reaches the command. When `True`, it is flag-shaped and
goes to the `unknown` policy like an undeclared `--x`. A lone `-` is a
positional either way.

Instances: `Eq`, `Debug`

### `Args`

```
data Args
  = Args { given : List (String, Option String), positionals : List String, rest : List String }
```

The result of a successful parse.

`given` holds each flag by its canonical name with its value, in the
order given, so `flagValue` takes the first occurrence and `lastValue`
the last. `positionals` holds the arguments no flag claimed, and `rest`
holds the trailing section.

Instances: `Eq`, `Debug`

## Building a specification

### `switch`

```
switch : List String -> String -> FlagSpec
```

A flag that takes no value.

```medaka
> canonical (switch ["--write", "-w"] "rewrite in place")
"--write"
```

### `value`

```
value : List String -> String -> String -> FlagSpec
```

A flag that takes one value, shown in help under the given name.

```medaka
> flagLabel (value ["--out", "-o"] "PATH" "where to write")
"--out, -o <PATH>"
```

### `valueList`

```
valueList : List String -> String -> String -> FlagSpec
```

A flag whose value is a comma-separated list.

The parser does not split the list; the caller does.

```medaka
> flagLabel (valueList ["--stages"] "STAGES" "stages to render")
"--stages=<STAGES>"
```

### `oneOf`

```
oneOf : List String -> List String -> String -> FlagSpec
```

A flag whose value must be one of a fixed set.

Help and the error for a bad value both list the set.

```medaka
> flagLabel (oneOf ["--engine"] ["eval", "native"] "which engine")
"--engine <eval|native>"
```

### `intValue`

```
intValue : List String -> String -> String -> FlagSpec
```

A flag whose value must be an integer.

```medaka
> flagLabel (intValue ["--jobs"] "N" "worker count")
"--jobs <N>"
```

### `internal`

```
internal : FlagSpec -> FlagSpec
```

The flag hidden from help.

It is still parsed and still listed in `rosterOf`.

```medaka
> helpBlockOf (spec "check" [internal (switch ["--allow-internal"] "x")])
""
```

### `spec`

```
spec : String -> List FlagSpec -> ArgSpec
```

A specification for the command `v` with the given flags, no trailing
section, and unknown flags rejected.

```medaka
> rosterOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place"])
["--write", "-w"]
```

### `withTrailing`

```
withTrailing : Trailing -> ArgSpec -> ArgSpec
```

The specification with a trailing-section policy.

### `withUnknown`

```
withUnknown : Unknown -> ArgSpec -> ArgSpec
```

The specification with an unknown-flag policy.

### `withStrictDash`

```
withStrictDash : ArgSpec -> ArgSpec
```

The specification with undeclared single-dash tokens treated as flags.

See `ArgSpec`.

```medaka
> parseArgs (withStrictDash (spec "x" [])) ["-foo"]
Err "medaka x: unrecognized flag '-foo' (known: none)"
```

## Renderings of a specification

### `canonical`

```
canonical : FlagSpec -> String
```

A flag's canonical name, the first in its `names`.

```medaka
> canonical (switch ["-w"] "rewrite in place")
"-w"
```

### `rosterOf`

```
rosterOf : ArgSpec -> List String
```

Every name of every flag, in declaration order.

This is the `(known: ...)` list in an unknown-flag error.

```medaka
> rosterOf (spec "run" [switch ["--json"] "j", switch ["--release", "-r"] "r"])
["--json", "--release", "-r"]
```

### `unknownFlagMessage`

```
unknownFlagMessage : ArgSpec -> String -> String
```

The error for a flag the specification does not know.

```medaka
> unknownFlagMessage (spec "fmt" [switch ["--write", "-w"] "w"]) "--zzz"
"medaka fmt: unrecognized flag '--zzz' (known: --write, -w)"
```

### `missingValueMessage`

```
missingValueMessage : ArgSpec -> String -> String
```

The error for a flag given without its value. `flg` is the flag as
typed.

```medaka
> missingValueMessage (spec "build" [value ["-o"] "PATH" "out"]) "-o"
"medaka build: -o requires a value"
```

### `invalidValueMessage`

```
invalidValueMessage : ArgSpec -> String -> String -> String
```

The error for a value a `OneOf` or `IntValue` flag does not accept.

```medaka
> invalidValueMessage (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) "--engine" "zzz"
"medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
> invalidValueMessage (spec "gate" [intValue ["--jobs"] "N" "j"]) "--jobs" "x"
"medaka gate: --jobs: expected an integer, got 'x'"
```

### `helpBlockOf`

```
helpBlockOf : ArgSpec -> String
```

The flag table of a help message: one row per public flag, in two
columns, with no trailing newline.

`""` when the specification has no public flags.

```medaka
> helpBlockOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place", value ["--out"] "PATH" "where to write"])
"  --write, -w    rewrite in place\n  --out <PATH>   where to write"
```

### `flagLabel`

```
flagLabel : FlagSpec -> String
```

The left column of a flag's help row: every spelling, then its value
name.

```medaka
> flagLabel (switch ["--check"] "check only")
"--check"
```

### `usageExitCode`

```
usageExitCode : Int
```

The exit code for a usage error.

```medaka
> usageExitCode
1
```

## Parsing

### `parseArgs`

```
parseArgs : ArgSpec -> List String -> Result String Args
```

The arguments parsed against a specification, or `Err` with an error
sentence ready to print. A caller that prints it exits with
`usageExitCode`.

```medaka
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o", "x"])
Ok Some "x"
> map (a => a.positionals) (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["a.mdk", "--write", "b.mdk"])
Ok ["a.mdk", "b.mdk"]
> map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--zzz"])
Err "medaka fmt: unrecognized flag '--zzz' (known: --write, -w)"
```

## Querying a parse

### `flag`

```
flag : String -> Args -> Bool
```

Whether the flag was given.

```medaka
> map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) [])
Ok False
```

### `flagValue`

```
flagValue : String -> Args -> Option String
```

The value of the flag's first occurrence, or `None`.

```medaka
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok Some "a"
```

### `lastValue`

```
lastValue : String -> Args -> Option String
```

The value of the flag's last occurrence, or `None`.

```medaka
> map (a => lastValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok Some "b"
```

### `flagValues`

```
flagValues : String -> Args -> List String
```

The values of every occurrence of the flag, in order.

```medaka
> map (a => flagValues "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok ["a", "b"]
```

## Instances

