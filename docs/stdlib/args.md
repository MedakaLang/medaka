# args

args.mdk — one command-line argument parser, as a first-order value

Design notes
────────────
See `docs/design/ARGS-DESIGN.md` for the decision and the rejected shapes.
The one-line version: a flag specification is a VALUE (`List FlagSpec`
inside an `ArgSpec`), never a combinator tree.  `rosterOf` and
`unknownFlagMessage`/`parseArgs` are unified renderings of that one value,
so a verb's `(known: …)` set and what it actually parses cannot drift
apart — that drift is the defect this module exists to close.
`helpBlockOf` and `flagLabel` exist as part of the frozen API surface
(F1, review finding, #2355) but have no live consumer yet.

Why not an `optparse-applicative`-style free applicative: it needs
existential quantification and Medaka has none (probed — the `b` in
`PAp (P (b -> a)) (P b)` is a rigid, scope-escaping type variable, not an
existential).  The only expressible combinator shape is the wrapped-function
one, which is opaque and therefore cannot derive help.

Cost posture: `FlagSpec` is four immutable fields of plain data.  The module
imports only `string` — every consumer already imports it, so nothing new
enters dispatch scope.  Per-flag lookup over `given` is a monomorphic fold
rather than a polymorphic `lookup`.  Adding a `map`/`hash_map` import
invalidates the measured import cost and must be re-measured
(`[T-STDLIB-IMPORT]`).

The seven types below carry `deriving (Eq, Debug)` and nothing else (sheet
row A-2, ratified #2306).  This paragraph previously said there were
deliberately NO `deriving` clauses; the ban was lifted, not forgotten — a
spec value that cannot be compared or printed cannot be asserted on in a
test, which is the defect A-2 names.  `Eq`/`Debug` are prelude interfaces,
so this adds no import; the re-measurement the old wording demanded was run
on `medaka check compiler/driver/medaka_cli.mdk` (the CLI is the module that
imports `args`) and is recorded in the sprint report.  The `map`/`hash_map`
import ban above still stands.

Wording: the four rejection sentences are the ratified ones from
`docs/ops/CLI-CONFORMANCE.md` (C2 unknown flag, C3 exit code 1).  They are
rendered here and nowhere else.

## `Arity`

```
data Arity
  = Switch
  | Value String
  | ValueList String
  | OneOf (List String) String
  | IntValue String
```

What a flag does with the token that follows it.

`Switch` takes no value.  `Value`/`ValueList`/`OneOf`/`IntValue` all take
one, in either C1 spelling (`--flag v` or `--flag=v`).  The trailing
`String` on each value-taking arm is the help METAVAR (`PATH`, `N`, …);
`OneOf` additionally carries the closed set its value must belong to, and
`IntValue` requires the value to parse as an integer.

`ValueList` differs from `Value` only in how it renders in help
(`--flag=<A,B>`) — splitting the comma list is the consumer's business.

## `Eq Arity`

```
impl Eq Arity
```

## `Debug Arity`

```
impl Debug Arity
```

## `Visibility`

```
data Visibility
  = Public
  | Internal
```

Whether a flag appears in `helpBlockOf`.  Both kinds appear in `rosterOf`.

## `Eq Visibility`

```
impl Eq Visibility
```

## `Debug Visibility`

```
impl Debug Visibility
```

## `Unknown`

```
data Unknown
  = RejectUnknown
  | CollectUnknown
```

What happens to a `--`-shaped token that no `FlagSpec` claims.

`RejectUnknown` is the C2 default.  `CollectUnknown` exists for a future
`codemod` migration (not yet done — F1, review finding, #2355), whose flag
vocabulary is per-codemod and therefore not statically knowable: an
unclaimed token is recorded in `given`, consuming the following token as
its value.

## `Eq Unknown`

```
impl Eq Unknown
```

## `Debug Unknown`

```
impl Debug Unknown
```

## `Trailing`

```
data Trailing
  = TrailingReject
  | TrailingRaw
  | TrailingAfterSeparator
```

How the verb treats a raw trailing section.

* `TrailingReject` — there is none.  `--` is not special and falls to the
unknown-flag path like any other `--`-shaped token.
* `TrailingRaw` — the FIRST positional ends flag scanning; everything after
it is the callee's argv, `--` included and NOT consumed (`medaka run`).
* `TrailingAfterSeparator` — the first bare `--` is consumed as a
separator and everything after it lands in `rest`.

## `Eq Trailing`

```
impl Eq Trailing
```

## `Debug Trailing`

```
impl Debug Trailing
```

## `FlagSpec`

```
data FlagSpec
  = FlagSpec { names : List String, arity : Arity, summary : String, visibility : Visibility }
```

One flag, with every spelling it answers to.

`names` carries complete tokens including their dashes, longest-canonical
first: `["--write", "-w"]`.  The head is the CANONICAL name — the key
`parseArgs` records in `Args.given` and the one `flag`/`flagValue` query
by, whichever spelling the user typed.

## `Eq FlagSpec`

```
impl Eq FlagSpec
```

## `Debug FlagSpec`

```
impl Debug FlagSpec
```

## `ArgSpec`

```
data ArgSpec
  = ArgSpec { verb : String, flags : List FlagSpec, trailing : Trailing, unknown : Unknown, strictDash : Bool }
```

One verb's whole argument vocabulary.  This is the value everything else
  in this module is a rendering of.

`strictDash` (S-5, #2355 residual A): whether an UNDECLARED single-dash
token (`-foo`, not `--foo`) is flag-shaped at all. `False` (the default,
via `spec`) is `isFlagToken`'s original lenient reading — an undeclared
`-x` is left to the positional/raw path, because a short token is also how
a filename starting with `-` reaches the CLI (the AS-FILENAME hole this
flag exists to let a verb opt OUT of). `True` (`withStrictDash`) makes an
undeclared `-x` flag-shaped like `--x` is: it flows into the SAME
`unknown` policy (`RejectUnknown`'s `unknownFlagMessage`, by default) that
an unclaimed `--`-shaped token already gets. Opt in per-verb, never
tree-wide by changing `isFlagToken`'s default — a verb that genuinely
wants positionals starting with `-` (a filename literally named `-` stays
exempt either way: `stringLength t > 1` guards that) keeps `False`.

## `Eq ArgSpec`

```
impl Eq ArgSpec
```

## `Debug ArgSpec`

```
impl Debug ArgSpec
```

## `Args`

```
data Args
  = Args { given : List (String, Option String), positionals : List String, rest : List String }
```

The result of a successful parse.

`given` keeps argv order, so a verb that wants first-occurrence semantics
calls `flagValue` and one that wants last-occurrence calls `lastValue` —
the tree contains both conventions and this module deliberately picks
neither for you.

## `Eq Args`

```
impl Eq Args
```

## `Debug Args`

```
impl Debug Args
```

## `switch`

```
switch : List String -> String -> FlagSpec
```

A flag taking no value.


*(doctest — run by `medaka test`)*

```medaka
> canonical (switch ["--write", "-w"] "rewrite in place")
"--write"
```

## `value`

```
value : List String -> String -> String -> FlagSpec
```

A flag taking one value, with a help metavar.


*(doctest — run by `medaka test`)*

```medaka
> flagLabel (value ["--out", "-o"] "PATH" "where to write")
"--out, -o <PATH>"
```

## `valueList`

```
valueList : List String -> String -> String -> FlagSpec
```

A flag whose value is a comma-separated list.  Renders as `--flag=<M>` in
help; the split itself is the consumer's business.


*(doctest — run by `medaka test`)*

```medaka
> flagLabel (valueList ["--stages"] "STAGES" "stages to render")
"--stages=<STAGES>"
```

## `oneOf`

```
oneOf : List String -> List String -> String -> FlagSpec
```

A flag whose value must be a member of a closed set.  The metavar is the
set itself, so help and the rejection sentence stay in step.


*(doctest — run by `medaka test`)*

```medaka
> flagLabel (oneOf ["--engine"] ["eval", "native"] "which engine")
"--engine <eval|native>"
```

## `intValue`

```
intValue : List String -> String -> String -> FlagSpec
```

A flag whose value must parse as an integer.


*(doctest — run by `medaka test`)*

```medaka
> flagLabel (intValue ["--jobs"] "N" "worker count")
"--jobs <N>"
```

## `internal`

```
internal : FlagSpec -> FlagSpec
```

Hide a flag from `helpBlockOf`.  It stays in `rosterOf` and stays
parseable — an internal flag the rejection sentence refused to name would
be a worse lie than one help omits.


*(doctest — run by `medaka test`)*

```medaka
> helpBlockOf (spec "check" [internal (switch ["--allow-internal"] "x")])
""
```

## `spec`

```
spec : String -> List FlagSpec -> ArgSpec
```

A verb's spec with the conservative defaults: no trailing section,
unknown flags rejected.


*(doctest — run by `medaka test`)*

```medaka
> rosterOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place"])
["--write", "-w"]
```

## `withTrailing`

```
withTrailing : Trailing -> ArgSpec -> ArgSpec
```

Give a spec a trailing-section policy.

## `withUnknown`

```
withUnknown : Unknown -> ArgSpec -> ArgSpec
```

Give a spec an unknown-token policy.

## `withStrictDash`

```
withStrictDash : ArgSpec -> ArgSpec
```

Opt a spec into treating an UNDECLARED single-dash token as flag-shaped
(C2-rejectable) rather than a positional. See `ArgSpec.strictDash`.


*(doctest — run by `medaka test`)*

```medaka
> parseArgs (withStrictDash (spec "x" [])) ["-foo"]
Err "medaka x: unrecognized flag '-foo' (known: none)"
```

## `canonical`

```
canonical : FlagSpec -> String
```

The head of `names` — the key `parseArgs` records whichever spelling was
typed.


*(doctest — run by `medaka test`)*

```medaka
> canonical (switch ["-w"] "rewrite in place")
"-w"
```

## `rosterOf`

```
rosterOf : ArgSpec -> List String
```

The `(known: …)` set, in declaration order: EVERY name of every flag,
short spellings included.

An earlier draft filtered this to `--`-prefixed names on the theory that no
verb exposed a short flag yet.  That premise was false — `fmt` renders `-w`
and `build` renders `-o` in their `(known: …)` sentences today — so the
filter was a silent narrowing, not a deferral, and it is gone.


*(doctest — run by `medaka test`)*

```medaka
> rosterOf (spec "run" [switch ["--json"] "j", switch ["--release", "-r"] "r"])
["--json", "--release", "-r"]
```

## `unknownFlagMessage`

```
unknownFlagMessage : ArgSpec -> String -> String
```

The ratified C2 sentence (`docs/ops/CLI-CONFORMANCE.md` §2), rendered in
exactly one place.


*(doctest — run by `medaka test`)*

```medaka
> unknownFlagMessage (spec "fmt" [switch ["--write", "-w"] "w"]) "--zzz"
"medaka fmt: unrecognized flag '--zzz' (known: --write, -w)"
> unknownFlagMessage (spec "doc" []) "--zzz"
"medaka doc: unrecognized flag '--zzz' (known: none)"
```

## `missingValueMessage`

```
missingValueMessage : ArgSpec -> String -> String
```

The ratified missing-value sentence.  `flg` is the token as the user
spelled it, not the canonical name.


*(doctest — run by `medaka test`)*

```medaka
> missingValueMessage (spec "build" [value ["-o"] "PATH" "out"]) "-o"
"medaka build: -o requires a value"
```

## `invalidValueMessage`

```
invalidValueMessage : ArgSpec -> String -> String -> String
```

C2's shape one level down: the flag was recognized, its VALUE was not.
`OneOf` names the set the same way C2 names the flag set; `IntValue` says
what it wanted.


*(doctest — run by `medaka test`)*

```medaka
> invalidValueMessage (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) "--engine" "zzz"
"medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
> invalidValueMessage (spec "gate" [intValue ["--jobs"] "N" "j"]) "--jobs" "x"
"medaka gate: --jobs: expected an integer, got 'x'"
```

## `helpBlockOf`

```
helpBlockOf : ArgSpec -> String
```

The flag half of a `--help` block: two columns, `Internal` flags omitted,
no trailing newline.  A spec with no public flags renders `""`.


*(doctest — run by `medaka test`)*

```medaka
> helpBlockOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place", value ["--out"] "PATH" "where to write"])
"  --write, -w    rewrite in place\n  --out <PATH>   where to write"
```

## `flagLabel`

```
flagLabel : FlagSpec -> String
```

The left column of one help row: every spelling, then the metavar.


*(doctest — run by `medaka test`)*

```medaka
> flagLabel (switch ["--check"] "check only")
"--check"
```

## `usageExitCode`

```
usageExitCode : Int
```

The C3 exit code for every usage error this module can report — one
number, so a verb never has to decide.


*(doctest — run by `medaka test`)*

```medaka
> usageExitCode
1
```

## `parseArgs`

```
parseArgs : ArgSpec -> List String -> Result String Args
```

Parse argv against a spec.  `Err` carries the finished sentence, ready
for stderr; the caller exits `usageExitCode`.

A known switch, then the same flag by its short spelling:


*(doctest — run by `medaka test`)*

```medaka
> map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--write"])
Ok True
> map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["-w"])
Ok True
```

C1 — both value spellings reach the same canonical key:


*(doctest — run by `medaka test`)*

```medaka
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out", "x"])
Ok Some "x"
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out=x"])
Ok Some "x"
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o", "x"])
Ok Some "x"
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o=x"])
Ok Some "x"
```

C2 — an unclaimed `--`-shaped token, and a value flag with nothing after it:


*(doctest — run by `medaka test`)*

```medaka
> map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--zzz"])
Err "medaka fmt: unrecognized flag '--zzz' (known: --write, -w)"
> map (_ => "ok") (parseArgs (spec "fmt" [value ["--out"] "PATH" "o"]) ["--out"])
Err "medaka fmt: --out requires a value"
```

C2 stops at `--`.  An UNDECLARED single-dash token is not a flag-shaped
token at all — it is a positional, exactly as the CLI treats it today, so
that a filename beginning with `-` is not rejected here:


*(doctest — run by `medaka test`)*

```medaka
> map (a => a.positionals) (parseArgs (spec "check" [switch ["--json"] "j"]) ["-zzz", "f.mdk"])
Ok ["-zzz", "f.mdk"]
```

Positionals, in order, unclaimed by any flag:


*(doctest — run by `medaka test`)*

```medaka
> map (a => a.positionals) (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["a.mdk", "--write", "b.mdk"])
Ok ["a.mdk", "b.mdk"]
```

`OneOf` and `IntValue` check the value they took, in either spelling, and
render C2's shape one level down when it does not belong:


*(doctest — run by `medaka test`)*

```medaka
> map (a => flagValue "--engine" a) (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine", "native"])
Ok Some "native"
> map (_ => "ok") (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine=zzz"])
Err "medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
> map (a => flagValue "--jobs" a) (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "-3"])
Ok Some "-3"
> map (_ => "ok") (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "x"])
Err "medaka gate: --jobs: expected an integer, got 'x'"
```

`TrailingReject` (the default) gives `--` no meaning, so it rejects like
any other unclaimed token:


*(doctest — run by `medaka test`)*

```medaka
> map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["--"])
Err "medaka fmt: unrecognized flag '--' (known: --write)"
```

`TrailingRaw` ends the scan at the first positional; a literal `--` after
it reaches the callee UNCONSUMED, and so does a `--`-shaped token the spec
never heard of:


*(doctest — run by `medaka test`)*

```medaka
> map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["p.mdk", "--", "--foo"])
Ok ["--", "--foo"]
> map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["--json", "p.mdk", "--zzz"])
Ok ["--zzz"]
```

`TrailingAfterSeparator` consumes exactly ONE `--`; a second one is data:


*(doctest — run by `medaka test`)*

```medaka
> map (a => a.rest) (parseArgs (withTrailing TrailingAfterSeparator (spec "gate" [switch ["--json"] "j"])) ["--json", "--", "--x", "--"])
Ok ["--x", "--"]
```

`CollectUnknown` records a token no `FlagSpec` claims, for the one verb
(`codemod`) whose vocabulary is not statically knowable:


*(doctest — run by `medaka test`)*

```medaka
> map (a => flagValue "--anything" a) (parseArgs (withUnknown CollectUnknown (spec "codemod" [])) ["--anything", "v"])
Ok Some "v"
```

## `flag`

```
flag : String -> Args -> Bool
```

Was this flag given at all?


*(doctest — run by `medaka test`)*

```medaka
> map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) [])
Ok False
```

## `flagValue`

```
flagValue : String -> Args -> Option String
```

The FIRST occurrence's value.


*(doctest — run by `medaka test`)*

```medaka
> map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok Some "a"
```

## `lastValue`

```
lastValue : String -> Args -> Option String
```

The LAST occurrence's value.  Both conventions live in the tree; the
verb picks.


*(doctest — run by `medaka test`)*

```medaka
> map (a => lastValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok Some "b"
```

## `flagValues`

```
flagValues : String -> Args -> List String
```

Every occurrence's value, in argv order.


*(doctest — run by `medaka test`)*

```medaka
> map (a => flagValues "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
Ok ["a", "b"]
```

