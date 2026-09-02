# META
source_lines=646
stages=DESUGAR,MARK
# SOURCE
{- | A command-line argument parser.

   Describe a command's flags as a value, an `ArgSpec` built with `spec`
   and the flag constructors (`switch`, `value`, `oneOf`, `intValue`), then
   `parseArgs` turns an argument list into an `Args` or a finished error
   sentence. Because the specification is a value, the help text, the
   `(known: ...)` list in an error, and the parser itself all come from the
   same source and cannot disagree.

   A flag with a value accepts both `--flag v` and `--flag=v`. Every name
   in a flag's `names` list is accepted; the first is the canonical name
   the query functions use. -}

-- See `docs/design/ARGS-DESIGN.md` for the decision and the rejected shapes.
-- `helpBlockOf` and `flagLabel` exist as part of the frozen API surface but
-- have no live consumer yet.
--
-- Why not an `optparse-applicative`-style free applicative: it needs
-- existential quantification and Medaka has none (probed: the `b` in
-- `PAp (P (b -> a)) (P b)` is a rigid, scope-escaping type variable, not an
-- existential).  The only expressible combinator shape is the
-- wrapped-function one, which is opaque and therefore cannot derive help.
--
-- Cost posture: `FlagSpec` is four immutable fields of plain data.  The
-- module imports only `string`; every consumer already imports it, so
-- nothing new enters dispatch scope.  Per-flag lookup over `given` is a
-- monomorphic fold rather than a polymorphic `lookup`.  Adding a
-- `map`/`hash_map` import invalidates the measured import cost and must be
-- re-measured (`[T-STDLIB-IMPORT]`).
--
-- The rejection sentences are the ratified ones from
-- `docs/ops/CLI-CONFORMANCE.md` (C2 unknown flag, C3 exit code 1).  They are
-- rendered here and nowhere else.

import string.{startsWith, indexOf, join, toInt, repeat}

-- # Specifications

{- | What a flag does with the token after it.

   `Switch` takes no value. The others take one, and carry the name shown
   for it in help, such as `PATH` or `N`. `OneOf` also carries the set the
   value must belong to; `IntValue` requires the value to be an integer;
   `ValueList` is a comma-separated list, shown in help as `--flag=<M>` and
   split by the caller. -}
public export data Arity =
  | Switch
  | Value String
  | ValueList String
  | OneOf (List String) String
  | IntValue String
  deriving (Eq, Debug)

-- | Whether a flag appears in `helpBlockOf`. Both kinds appear in
-- `rosterOf` and are parsed.
public export data Visibility = Public | Internal deriving (Eq, Debug)

{- | What happens to a flag-shaped token no `FlagSpec` claims.

   `RejectUnknown` makes it an error. `CollectUnknown` records it in
   `given`, taking the next token as its value, for a command whose flags
   are not known in advance. -}
public export data Unknown = RejectUnknown | CollectUnknown deriving (Eq, Debug)

{- | How the command treats arguments after its own.

   `TrailingReject` means there are none, so `--` is an ordinary unknown
   flag. `TrailingRaw` ends flag scanning at the first positional and
   leaves everything after it, `--` included, in `rest`.
   `TrailingAfterSeparator` consumes the first `--` and puts everything
   after it in `rest`. -}
public export data Trailing =
  | TrailingReject
  | TrailingRaw
  | TrailingAfterSeparator
  deriving (Eq, Debug)

{- | One flag and every spelling it answers to.

   `names` holds complete tokens with their dashes, such as
   `["--write", "-w"]`. The first is the canonical name: the key recorded
   in `Args.given` and queried by `flag` and `flagValue`, whichever
   spelling was typed. -}
public export data FlagSpec = FlagSpec {
  names : List String,
  arity : Arity,
  summary : String,
  visibility : Visibility,
}
  deriving (Eq, Debug)

{- | A command's whole argument vocabulary.

   `strictDash` controls an undeclared single-dash token such as `-x`.
   When `False`, the default, it is a positional, so a file name starting
   with `-` still reaches the command. When `True`, it is flag-shaped and
   goes to the `unknown` policy like an undeclared `--x`. A lone `-` is a
   positional either way. -}
public export data ArgSpec = ArgSpec {
  verb : String,
  flags : List FlagSpec,
  trailing : Trailing,
  unknown : Unknown,
  strictDash : Bool,
}
  deriving (Eq, Debug)

{- | The result of a successful parse.

   `given` holds each flag by its canonical name with its value, in the
   order given, so `flagValue` takes the first occurrence and `lastValue`
   the last. `positionals` holds the arguments no flag claimed, and `rest`
   holds the trailing section. -}
public export data Args = Args {
  given : List (String, Option String),
  positionals : List String,
  rest : List String,
}
  deriving (Eq, Debug)

-- # Building a specification

{- | A flag that takes no value.

   > canonical (switch ["--write", "-w"] "rewrite in place")
   "--write" -}
export
switch : List String -> String -> FlagSpec
switch ns s =
  FlagSpec { names = ns, arity = Switch, summary = s, visibility = Public }

{- | A flag that takes one value, shown in help under the given name.

   > flagLabel (value ["--out", "-o"] "PATH" "where to write")
   "--out, -o <PATH>" -}
export
value : List String -> String -> String -> FlagSpec
value ns m s =
  FlagSpec { names = ns, arity = Value m, summary = s, visibility = Public }

{- | A flag whose value is a comma-separated list.

   The parser does not split the list; the caller does.

   > flagLabel (valueList ["--stages"] "STAGES" "stages to render")
   "--stages=<STAGES>" -}
export
valueList : List String -> String -> String -> FlagSpec
valueList ns m s = FlagSpec {
  names = ns,
  arity = ValueList m,
  summary = s,
  visibility = Public,
}

{- | A flag whose value must be one of a fixed set.

   Help and the error for a bad value both list the set.

   > flagLabel (oneOf ["--engine"] ["eval", "native"] "which engine")
   "--engine <eval|native>" -}
export
oneOf : List String -> List String -> String -> FlagSpec
oneOf ns ms s = FlagSpec {
  names = ns,
  arity = OneOf ms (join "|" ms),
  summary = s,
  visibility = Public,
}

{- | A flag whose value must be an integer.

   > flagLabel (intValue ["--jobs"] "N" "worker count")
   "--jobs <N>" -}
export
intValue : List String -> String -> String -> FlagSpec
intValue ns m s =
  FlagSpec { names = ns, arity = IntValue m, summary = s, visibility = Public }

{- | The flag hidden from help.

   It is still parsed and still listed in `rosterOf`.

   > helpBlockOf (spec "check" [internal (switch ["--allow-internal"] "x")])
   "" -}
export
internal : FlagSpec -> FlagSpec
internal f = { f | visibility = Internal }

{- | A specification for the command `v` with the given flags, no trailing
   section, and unknown flags rejected.

   > rosterOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place"])
   ["--write", "-w"] -}
export
spec : String -> List FlagSpec -> ArgSpec
spec v fs = ArgSpec {
  verb = v,
  flags = fs,
  trailing = TrailingReject,
  unknown = RejectUnknown,
  strictDash = False,
}

-- | The specification with a trailing-section policy.
export
withTrailing : Trailing -> ArgSpec -> ArgSpec
withTrailing t sp = { sp | trailing = t }

-- | The specification with an unknown-flag policy.
export
withUnknown : Unknown -> ArgSpec -> ArgSpec
withUnknown u sp = { sp | unknown = u }

{- | The specification with undeclared single-dash tokens treated as flags.

   See `ArgSpec`.

   > parseArgs (withStrictDash (spec "x" [])) ["-foo"]
   Err "medaka x: unrecognized flag '-foo' (known: none)" -}
export
withStrictDash : ArgSpec -> ArgSpec
withStrictDash sp = { sp | strictDash = True }

-- # Renderings of a specification

{- | A flag's canonical name, the first in its `names`.

   > canonical (switch ["-w"] "rewrite in place")
   "-w" -}
export
canonical : FlagSpec -> String
canonical f = match f.names
  n :: _ => n
  [] => ""

{- | Every name of every flag, in declaration order.

   This is the `(known: ...)` list in an unknown-flag error.

   > rosterOf (spec "run" [switch ["--json"] "j", switch ["--release", "-r"] "r"])
   ["--json", "--release", "-r"] -}
export
rosterOf : ArgSpec -> List String
rosterOf sp = rosterGo sp.flags

rosterGo : List FlagSpec -> List String
rosterGo [] = []
rosterGo (f :: rest) = f.names ++ rosterGo rest

-- Render a name set the way every rejection sentence does: a verb with no
-- flags at all says `none`, not an empty parenthesis.
knownSet : List String -> String
knownSet [] = "none"
knownSet ns = join ", " ns

{- | The error for a flag the specification does not know.

   > unknownFlagMessage (spec "fmt" [switch ["--write", "-w"] "w"]) "--zzz"
   "medaka fmt: unrecognized flag '--zzz' (known: --write, -w)" -}
export
unknownFlagMessage : ArgSpec -> String -> String
unknownFlagMessage sp tok =
  "medaka \{sp.verb}: unrecognized flag '\{tok}' (known: \{knownSet (rosterOf sp)})"

-- > unknownFlagMessage (spec "doc" []) "--zzz"
-- "medaka doc: unrecognized flag '--zzz' (known: none)"

{- | The error for a flag given without its value. `flg` is the flag as
   typed.

   > missingValueMessage (spec "build" [value ["-o"] "PATH" "out"]) "-o"
   "medaka build: -o requires a value" -}
export
missingValueMessage : ArgSpec -> String -> String
missingValueMessage sp flg = "medaka \{sp.verb}: \{flg} requires a value"

{- | The error for a value a `OneOf` or `IntValue` flag does not accept.

   > invalidValueMessage (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) "--engine" "zzz"
   "medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
   > invalidValueMessage (spec "gate" [intValue ["--jobs"] "N" "j"]) "--jobs" "x"
   "medaka gate: --jobs: expected an integer, got 'x'" -}
export
invalidValueMessage : ArgSpec -> String -> String -> String
invalidValueMessage sp flg v = match findFlag flg sp.flags
  Some f => arityValueMessage sp.verb flg v f.arity
  None => "medaka \{sp.verb}: \{flg}: unrecognized value '\{v}'"

arityValueMessage : String -> String -> String -> Arity -> String
arityValueMessage vb flg v (OneOf ms _) =
  "medaka \{vb}: \{flg}: unrecognized value '\{v}' (known: \{knownSet ms})"
arityValueMessage vb flg v (IntValue _) =
  "medaka \{vb}: \{flg}: expected an integer, got '\{v}'"
arityValueMessage vb flg v _ = "medaka \{vb}: \{flg}: unrecognized value '\{v}'"

{- | The flag table of a help message: one row per public flag, in two
   columns, with no trailing newline.

   `""` when the specification has no public flags.

   > helpBlockOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place", value ["--out"] "PATH" "where to write"])
   "  --write, -w    rewrite in place\n  --out <PATH>   where to write" -}
export
helpBlockOf : ArgSpec -> String
helpBlockOf sp =
  let pubs = publicFlags sp.flags
  helpLines pubs (labelWidth pubs 0)

{- | The left column of a flag's help row: every spelling, then its value
   name.

   > flagLabel (switch ["--check"] "check only")
   "--check" -}
export
flagLabel : FlagSpec -> String
flagLabel f =
  let ns = join ", " f.names
  match f.arity
    Switch => ns
    Value m => "\{ns} <\{m}>"
    ValueList m => "\{ns}=<\{m}>"
    OneOf _ m => "\{ns} <\{m}>"
    IntValue m => "\{ns} <\{m}>"

publicFlags : List FlagSpec -> List FlagSpec
publicFlags [] = []
publicFlags (f :: rest) = match f.visibility
  Public => f :: publicFlags rest
  Internal => publicFlags rest

labelWidth : List FlagSpec -> Int -> Int
labelWidth [] acc = acc
labelWidth (f :: rest) acc =
  let n = stringLength (flagLabel f)
  labelWidth rest (max n acc)

helpLines : List FlagSpec -> Int -> String
helpLines [] _ = ""
helpLines (f :: rest) w =
  let lbl = flagLabel f
  let line = "  \{lbl}\{repeat (w - stringLength lbl + 3) " "}\{f.summary}"
  match rest
    [] => line
    _ => "\{line}\n\{helpLines rest w}"

{- | The exit code for a usage error.

   > usageExitCode
   1 -}
export
usageExitCode : Int
usageExitCode = 1

-- # Parsing

{- | The arguments parsed against a specification, or `Err` with an error
   sentence ready to print. A caller that prints it exits with
   `usageExitCode`.

   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o", "x"])
   Ok Some "x"
   > map (a => a.positionals) (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["a.mdk", "--write", "b.mdk"])
   Ok ["a.mdk", "b.mdk"]
   > map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--zzz"])
   Err "medaka fmt: unrecognized flag '--zzz' (known: --write, -w)" -}
export
parseArgs : ArgSpec -> List String -> Result String Args
parseArgs sp argv =
  map
    ((gs, ps, rs) => Args { given = gs, positionals = ps, rest = rs })
    (scanArgs sp argv)

-- A known switch, then the same flag by its short spelling:
-- > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--write"])
-- Ok True
-- > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["-w"])
-- Ok True
--
-- C1: both value spellings reach the same canonical key:
-- > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out", "x"])
-- Ok Some "x"
-- > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out=x"])
-- Ok Some "x"
-- > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o=x"])
-- Ok Some "x"
--
-- C2: a value flag with nothing after it:
-- > map (_ => "ok") (parseArgs (spec "fmt" [value ["--out"] "PATH" "o"]) ["--out"])
-- Err "medaka fmt: --out requires a value"
--
-- An undeclared single-dash token is a positional, so a filename beginning
-- with `-` is not rejected here:
-- > map (a => a.positionals) (parseArgs (spec "check" [switch ["--json"] "j"]) ["-zzz", "f.mdk"])
-- Ok ["-zzz", "f.mdk"]
--
-- `OneOf` and `IntValue` check the value they took, in either spelling:
-- > map (a => flagValue "--engine" a) (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine", "native"])
-- Ok Some "native"
-- > map (_ => "ok") (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine=zzz"])
-- Err "medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
-- > map (a => flagValue "--jobs" a) (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "-3"])
-- Ok Some "-3"
-- > map (_ => "ok") (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "x"])
-- Err "medaka gate: --jobs: expected an integer, got 'x'"
--
-- `TrailingReject` (the default) gives `--` no meaning:
-- > map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["--"])
-- Err "medaka fmt: unrecognized flag '--' (known: --write)"
--
-- `TrailingRaw` ends the scan at the first positional; a literal `--` after
-- it reaches the callee unconsumed, and so does an unknown `--` token:
-- > map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["p.mdk", "--", "--foo"])
-- Ok ["--", "--foo"]
-- > map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["--json", "p.mdk", "--zzz"])
-- Ok ["--zzz"]
--
-- `TrailingAfterSeparator` consumes exactly one `--`; a second one is data:
-- > map (a => a.rest) (parseArgs (withTrailing TrailingAfterSeparator (spec "gate" [switch ["--json"] "j"])) ["--json", "--", "--x", "--"])
-- Ok ["--x", "--"]
--
-- `CollectUnknown` records a token no `FlagSpec` claims:
-- > map (a => flagValue "--anything" a) (parseArgs (withUnknown CollectUnknown (spec "codemod" [])) ["--anything", "v"])
-- Ok Some "v"

-- The scanner's carrier: the three `Args` fields, still being built, or the
-- finished rejection sentence.
type Scan = Result String (List (String, Option String), List String, List String)

-- The scanner.  Returns the three `Args` fields in argv order, so nothing is
-- accumulated backwards and nothing has to be reversed.
scanArgs : ArgSpec -> List String -> Scan
scanArgs _ [] = Ok ([], [], [])
scanArgs sp (t :: rest)
  | t == "--" && isAfterSeparator sp.trailing = Ok ([], [], rest)
  | isFlagToken sp t = scanFlag sp t rest
  | isRaw sp.trailing = Ok ([], [t], rest)
  | otherwise = consPositional t (scanArgs sp rest)

-- A `-`-shaped token.  `--`-prefixed tokens are always flag-shaped, claimed
-- or not, so an unknown one rejects: `-` alone is a conventional
-- stdin/stdout placeholder and is a positional, but `--` is not; under
-- `TrailingReject`/`TrailingRaw` it has no meaning, and falling here is what
-- makes it reject like any other unclaimed token.
--
-- A single-dash token is flag-shaped when the spec declares it (in either C1
-- spelling, so `-o` and `-o=x` both qualify) or the spec opted into
-- `strictDash`; an undeclared `-zzz` is otherwise left to the
-- positional/raw path rather than rejected, because a short token is also
-- how a filename starting with `-` reaches the CLI.
isFlagToken : ArgSpec -> String -> Bool
isFlagToken sp t
  | startsWith "--" t = True
  | startsWith "-" t && stringLength t > 1 =
    isDeclaredShort sp t || sp.strictDash
  | otherwise = False

isDeclaredShort : ArgSpec -> String -> Bool
isDeclaredShort sp t = match splitEq t
  Some (nm, _) => declares nm sp.flags
  None => declares t sp.flags

declares : String -> List FlagSpec -> Bool
declares nm fs = match findFlag nm fs
  Some _ => True
  None => False

isAfterSeparator : Trailing -> Bool
isAfterSeparator TrailingAfterSeparator = True
isAfterSeparator _ = False

isRaw : Trailing -> Bool
isRaw TrailingRaw = True
isRaw _ = False

consPositional : String -> Scan -> Scan
consPositional t r = map ((gs, ps, rs) => (gs, t :: ps, rs)) r

consGiven : (String, Option String) -> Scan -> Scan
consGiven g r = map ((gs, ps, rs) => (g :: gs, ps, rs)) r

scanFlag : ArgSpec -> String -> List String -> Scan
scanFlag sp t rest = match findFlag t sp.flags
  Some f => scanKnown sp t f rest
  None => match splitEq t
    Some (nm, v) => scanEqForm sp t nm v rest
    None => scanUnclaimed sp t rest

-- The space spelling: `--flag` on its own, or `--flag v`.
scanKnown : ArgSpec -> String -> FlagSpec -> List String -> Scan
scanKnown sp t f rest = match f.arity
  Switch => consGiven (canonical f, None) (scanArgs sp rest)
  _ => match rest
    [] => Err (missingValueMessage sp t)
    v :: rest2 => match checkValue sp t f.arity v
      Err m => Err m
      Ok _ => consGiven (canonical f, Some v) (scanArgs sp rest2)

-- The `=` spelling: `--flag=v`.  A switch given `--flag=v` was not spelled by
-- any name in the spec, so it is an unclaimed token, not a silently dropped
-- value.
scanEqForm : ArgSpec -> String -> String -> String -> List String -> Scan
scanEqForm sp t nm v rest = match findFlag nm sp.flags
  None => scanUnclaimed sp t rest
  Some f => match f.arity
    Switch => scanUnclaimed sp t rest
    _ => match checkValue sp nm f.arity v
      Err m => Err m
      Ok _ => consGiven (canonical f, Some v) (scanArgs sp rest)

-- No `FlagSpec` claims this token.
scanUnclaimed : ArgSpec -> String -> List String -> Scan
scanUnclaimed sp t rest = match sp.unknown
  RejectUnknown => Err (unknownFlagMessage sp t)
  CollectUnknown => match splitEq t
    Some (nm, v) => consGiven (nm, Some v) (scanArgs sp rest)
    None => match rest
      [] => consGiven (t, None) (scanArgs sp [])
      v :: rest2 => consGiven (t, Some v) (scanArgs sp rest2)

checkValue : ArgSpec -> String -> Arity -> String -> Result String Unit
checkValue sp flg (OneOf ms _) v =
  if hasName v ms then Ok () else Err (invalidValueMessage sp flg v)
checkValue sp flg (IntValue _) v = match toInt v
  Some _ => Ok ()
  None => Err (invalidValueMessage sp flg v)
checkValue _ _ _ _ = Ok ()

findFlag : String -> List FlagSpec -> Option FlagSpec
findFlag _ [] = None
findFlag nm (f :: rest)
  | hasName nm f.names = Some f
  | otherwise = findFlag nm rest

hasName : String -> List String -> Bool
hasName _ [] = False
hasName nm (n :: rest) = n == nm || hasName nm rest

-- `--flag=v` → `("--flag", "v")`.  An `=` at position 0 is not a split.
splitEq : String -> Option (String, String)
splitEq t = match indexOf "=" t
  None => None
  Some i =>
    if i <= 0 then
      None
    else
      Some (stringSlice 0 i t, stringSlice (i + 1) (stringLength t) t)

-- # Querying a parse

-- All four query by the canonical name (the head of the flag's `names`),
-- whichever spelling the user typed.

{- | Whether the flag was given.

   > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) [])
   Ok False -}
export
flag : String -> Args -> Bool
flag nm a = hasKey nm a.given

hasKey : String -> List (String, Option String) -> Bool
hasKey _ [] = False
hasKey nm ((k, _) :: rest) = k == nm || hasKey nm rest

{- | The value of the flag's first occurrence, or `None`.

   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok Some "a" -}
export
flagValue : String -> Args -> Option String
flagValue nm a = firstValue nm a.given

firstValue : String -> List (String, Option String) -> Option String
firstValue _ [] = None
firstValue nm ((k, v) :: rest)
  | k == nm = v
  | otherwise = firstValue nm rest

{- | The value of the flag's last occurrence, or `None`.

   > map (a => lastValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok Some "b" -}
export
lastValue : String -> Args -> Option String
lastValue nm a = lastValueGo nm a.given None

lastValueGo : String ->
  List (String, Option String) ->
  Option String ->
  Option String
lastValueGo _ [] acc = acc
lastValueGo nm ((k, v) :: rest) acc
  | k == nm = lastValueGo nm rest v
  | otherwise = lastValueGo nm rest acc

{- | The values of every occurrence of the flag, in order.

   > map (a => flagValues "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok ["a", "b"] -}
export
flagValues : String -> Args -> List String
flagValues nm a = valuesGo nm a.given

valuesGo : String -> List (String, Option String) -> List String
valuesGo _ [] = []
valuesGo nm ((k, v) :: rest)
  | k == nm = match v
    Some s => s :: valuesGo nm rest
    None => valuesGo nm rest
  | otherwise = valuesGo nm rest

-- ── Instance laws ──────────────────────────────────────────────────────────
-- The point of `Eq`/`Debug` here is that a parse RESULT and a SPEC can be
-- asserted on directly in a test.  Both laws are stated against that use.

-- LAW: `Eq Args` must discriminate on all three fields, so a test asserting on
-- a parse result cannot pass while the parse dropped a positional or a flag.
prop "Eq Args discriminates every field" (v : String) =
  let base = Args { given = [("--out", Some v)], positionals = [v], rest = [] }
  base == Args { given = [("--out", Some v)], positionals = [v], rest = [] }
    && base == Args { base | given = [("--out", None)] } == False
    && base == Args { base | positionals = [] } == False
    && base == Args { base | rest = [v] } == False

-- LAW: `Eq ArgSpec` reaches through `FlagSpec`/`Arity`/`Visibility`: a spec
-- that answers to different flags, or to the same flag with a different
-- arity, must not compare equal.  (This is the composite the seven cells
-- exist for: comparing an `ArgSpec` exercises every one of the seven
-- instances.)
prop "Eq ArgSpec reaches through FlagSpec and Arity" (n : String) =
  let a = spec "fmt" [switch ["--write"] n]
  let b = spec "fmt" [switch ["--check"] n]
  let c = spec "fmt" [value ["--write"] "P" n]
  a == spec "fmt" [switch ["--write"] n]
    && a == b == False
    && a == c == False
    && a == spec "lint" [switch ["--write"] n] == False

-- LAW: `Debug` agrees with `Eq` on the composite: equal specs render
-- identically, unequal ones render differently, so a failing assertion's
-- printed value actually explains the failure.
prop "Debug ArgSpec agrees with Eq" (n : String) =
  let a = spec "fmt" [switch ["--write"] n]
  debug a == debug (spec "fmt" [switch ["--write"] n])
    && debug a == debug (spec "fmt" [switch ["--check"] n]) == False
# DESUGAR
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "indexOf" false) (mem "join" false) (mem "toInt" false) (mem "repeat" false))))
(DData Public "Arity" () ((variant "Switch" (ConPos)) (variant "Value" (ConPos (TyCon "String"))) (variant "ValueList" (ConPos (TyCon "String"))) (variant "OneOf" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "IntValue" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Arity")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Switch") (PCon "Switch")) () (EVar "True")) (arm (PTuple (PCon "Value" (PVar "__a0")) (PCon "Value" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ValueList" (PVar "__a0")) (PCon "ValueList" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "OneOf" (PVar "__a0") (PVar "__a1")) (PCon "OneOf" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "IntValue" (PVar "__a0")) (PCon "IntValue" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Arity")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Switch") () (ELit (LString "Switch"))) (arm (PCon "Value" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Value ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "ValueList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ValueList ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "OneOf" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "OneOf ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "IntValue" (PVar "__a0")) () (EBinOp "++" (ELit (LString "IntValue ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "Visibility" () ((variant "Public" (ConPos)) (variant "Internal" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Visibility")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Public") (PCon "Public")) () (EVar "True")) (arm (PTuple (PCon "Internal") (PCon "Internal")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Visibility")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Public") () (ELit (LString "Public"))) (arm (PCon "Internal") () (ELit (LString "Internal")))))))
(DData Public "Unknown" () ((variant "RejectUnknown" (ConPos)) (variant "CollectUnknown" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Unknown")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RejectUnknown") (PCon "RejectUnknown")) () (EVar "True")) (arm (PTuple (PCon "CollectUnknown") (PCon "CollectUnknown")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Unknown")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RejectUnknown") () (ELit (LString "RejectUnknown"))) (arm (PCon "CollectUnknown") () (ELit (LString "CollectUnknown")))))))
(DData Public "Trailing" () ((variant "TrailingReject" (ConPos)) (variant "TrailingRaw" (ConPos)) (variant "TrailingAfterSeparator" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Trailing")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TrailingReject") (PCon "TrailingReject")) () (EVar "True")) (arm (PTuple (PCon "TrailingRaw") (PCon "TrailingRaw")) () (EVar "True")) (arm (PTuple (PCon "TrailingAfterSeparator") (PCon "TrailingAfterSeparator")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Trailing")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TrailingReject") () (ELit (LString "TrailingReject"))) (arm (PCon "TrailingRaw") () (ELit (LString "TrailingRaw"))) (arm (PCon "TrailingAfterSeparator") () (ELit (LString "TrailingAfterSeparator")))))))
(DData Public "FlagSpec" () ((variant "FlagSpec" (ConNamed (field "names" (TyApp (TyCon "List") (TyCon "String"))) (field "arity" (TyCon "Arity")) (field "summary" (TyCon "String")) (field "visibility" (TyCon "Visibility"))))) ())
(DImpl true "Eq" ((TyCon "FlagSpec")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FlagSpec" ((rf "names" (PVar "__a0")) (rf "arity" (PVar "__a1")) (rf "summary" (PVar "__a2")) (rf "visibility" (PVar "__a3"))) false) (PRec "FlagSpec" ((rf "names" (PVar "__b0")) (rf "arity" (PVar "__b1")) (rf "summary" (PVar "__b2")) (rf "visibility" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FlagSpec")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FlagSpec" ((rf "names" (PVar "__a0")) (rf "arity" (PVar "__a1")) (rf "summary" (PVar "__a2")) (rf "visibility" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FlagSpec {")) (ELit (LString " names = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", arity = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", summary = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", visibility = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "ArgSpec" () ((variant "ArgSpec" (ConNamed (field "verb" (TyCon "String")) (field "flags" (TyApp (TyCon "List") (TyCon "FlagSpec"))) (field "trailing" (TyCon "Trailing")) (field "unknown" (TyCon "Unknown")) (field "strictDash" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "ArgSpec")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ArgSpec" ((rf "verb" (PVar "__a0")) (rf "flags" (PVar "__a1")) (rf "trailing" (PVar "__a2")) (rf "unknown" (PVar "__a3")) (rf "strictDash" (PVar "__a4"))) false) (PRec "ArgSpec" ((rf "verb" (PVar "__b0")) (rf "flags" (PVar "__b1")) (rf "trailing" (PVar "__b2")) (rf "unknown" (PVar "__b3")) (rf "strictDash" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "ArgSpec")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ArgSpec" ((rf "verb" (PVar "__a0")) (rf "flags" (PVar "__a1")) (rf "trailing" (PVar "__a2")) (rf "unknown" (PVar "__a3")) (rf "strictDash" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ArgSpec {")) (ELit (LString " verb = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", flags = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", trailing = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", unknown = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", strictDash = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "Args" () ((variant "Args" (ConNamed (field "given" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) (field "positionals" (TyApp (TyCon "List") (TyCon "String"))) (field "rest" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DImpl true "Eq" ((TyCon "Args")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Args" ((rf "given" (PVar "__a0")) (rf "positionals" (PVar "__a1")) (rf "rest" (PVar "__a2"))) false) (PRec "Args" ((rf "given" (PVar "__b0")) (rf "positionals" (PVar "__b1")) (rf "rest" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "Args")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Args" ((rf "given" (PVar "__a0")) (rf "positionals" (PVar "__a1")) (rf "rest" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Args {")) (ELit (LString " given = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", positionals = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", rest = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "switch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "FlagSpec"))))
(DFunDef false "switch" ((PVar "ns") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EVar "Switch")) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "value" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "value" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "Value") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "valueList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "valueList" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "ValueList") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "oneOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "oneOf" ((PVar "ns") (PVar "ms") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EApp (EVar "OneOf") (EVar "ms")) (EApp (EApp (EVar "join") (ELit (LString "|"))) (EVar "ms")))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "intValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "intValue" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "IntValue") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "internal" (TyFun (TyCon "FlagSpec") (TyCon "FlagSpec")))
(DFunDef false "internal" ((PVar "f")) (ERecordUpdate (EVar "f") ((fa "visibility" (EVar "Internal")))))
(DTypeSig true "spec" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyCon "ArgSpec"))))
(DFunDef false "spec" ((PVar "v") (PVar "fs")) (ERecordCreate "ArgSpec" ((fa "verb" (EVar "v")) (fa "flags" (EVar "fs")) (fa "trailing" (EVar "TrailingReject")) (fa "unknown" (EVar "RejectUnknown")) (fa "strictDash" (EVar "False")))))
(DTypeSig true "withTrailing" (TyFun (TyCon "Trailing") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withTrailing" ((PVar "t") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "trailing" (EVar "t")))))
(DTypeSig true "withUnknown" (TyFun (TyCon "Unknown") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withUnknown" ((PVar "u") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "unknown" (EVar "u")))))
(DTypeSig true "withStrictDash" (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec")))
(DFunDef false "withStrictDash" ((PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "strictDash" (EVar "True")))))
(DTypeSig true "canonical" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "canonical" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "names") (arm (PCons (PVar "n") PWild) () (EVar "n")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "rosterOf" (TyFun (TyCon "ArgSpec") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterOf" ((PVar "sp")) (EApp (EVar "rosterGo") (EFieldAccess (EVar "sp") "flags")))
(DTypeSig false "rosterGo" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterGo" ((PList)) (EListLit))
(DFunDef false "rosterGo" ((PCons (PVar "f") (PVar "rest"))) (EBinOp "++" (EFieldAccess (EVar "f") "names") (EApp (EVar "rosterGo") (EVar "rest"))))
(DTypeSig false "knownSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "knownSet" ((PList)) (ELit (LString "none")))
(DFunDef false "knownSet" ((PVar "ns")) (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "ns")))
(DTypeSig true "unknownFlagMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unknownFlagMessage" ((PVar "sp") (PVar "tok")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": unrecognized flag '"))) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' (known: "))) (EApp (EVar "display") (EApp (EVar "knownSet") (EApp (EVar "rosterOf") (EVar "sp"))))) (ELit (LString ")"))))
(DTypeSig true "missingValueMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "missingValueMessage" ((PVar "sp") (PVar "flg")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "flg"))) (ELit (LString " requires a value"))))
(DTypeSig true "invalidValueMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "invalidValueMessage" ((PVar "sp") (PVar "flg") (PVar "v")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "flg")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EApp (EApp (EVar "arityValueMessage") (EFieldAccess (EVar "sp") "verb")) (EVar "flg")) (EVar "v")) (EFieldAccess (EVar "f") "arity"))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))))
(DTypeSig false "arityValueMessage" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Arity") (TyCon "String"))))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") (PCon "OneOf" (PVar "ms") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "' (known: "))) (EApp (EVar "display") (EApp (EVar "knownSet") (EVar "ms")))) (ELit (LString ")"))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") (PCon "IntValue" PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "flg"))) (ELit (LString ": expected an integer, got '"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))
(DTypeSig true "helpBlockOf" (TyFun (TyCon "ArgSpec") (TyCon "String")))
(DFunDef false "helpBlockOf" ((PVar "sp")) (EBlock (DoLet false false (PVar "pubs") (EApp (EVar "publicFlags") (EFieldAccess (EVar "sp") "flags"))) (DoExpr (EApp (EApp (EVar "helpLines") (EVar "pubs")) (EApp (EApp (EVar "labelWidth") (EVar "pubs")) (ELit (LInt 0)))))))
(DTypeSig true "flagLabel" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "flagLabel" ((PVar "f")) (EBlock (DoLet false false (PVar "ns") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EFieldAccess (EVar "f") "names"))) (DoExpr (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EVar "ns")) (arm (PCon "Value" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "ValueList" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ns"))) (ELit (LString "=<"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "OneOf" PWild (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "IntValue" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ">"))))))))
(DTypeSig false "publicFlags" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "FlagSpec"))))
(DFunDef false "publicFlags" ((PList)) (EListLit))
(DFunDef false "publicFlags" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EFieldAccess (EVar "f") "visibility") (arm (PCon "Public") () (EBinOp "::" (EVar "f") (EApp (EVar "publicFlags") (EVar "rest")))) (arm (PCon "Internal") () (EApp (EVar "publicFlags") (EVar "rest")))))
(DTypeSig false "labelWidth" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "labelWidth" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "labelWidth" ((PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EApp (EVar "flagLabel") (EVar "f")))) (DoExpr (EApp (EApp (EVar "labelWidth") (EVar "rest")) (EApp (EApp (EVar "max") (EVar "n")) (EVar "acc"))))))
(DTypeSig false "helpLines" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "helpLines" ((PList) PWild) (ELit (LString "")))
(DFunDef false "helpLines" ((PCons (PVar "f") (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "lbl") (EApp (EVar "flagLabel") (EVar "f"))) (DoLet false false (PVar "line") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "lbl"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "repeat") (EBinOp "+" (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "lbl"))) (ELit (LInt 3)))) (ELit (LString " "))))) (ELit (LString ""))) (EApp (EVar "display") (EFieldAccess (EVar "f") "summary"))) (ELit (LString "")))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (EVar "line")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EApp (EVar "helpLines") (EVar "rest")) (EVar "w")))) (ELit (LString ""))))))))
(DTypeSig true "usageExitCode" (TyCon "Int"))
(DFunDef false "usageExitCode" () (ELit (LInt 1)))
(DTypeSig true "parseArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Args")))))
(DFunDef false "parseArgs" ((PVar "sp") (PVar "argv")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ERecordCreate "Args" ((fa "given" (EVar "gs")) (fa "positionals" (EVar "ps")) (fa "rest" (EVar "rs")))))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "argv"))))
(DTypeAlias false "Scan" () (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DTypeSig false "scanArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan"))))
(DFunDef false "scanArgs" (PWild (PList)) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EListLit))))
(DFunDef false "scanArgs" ((PVar "sp") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "t") (ELit (LString "--"))) (EApp (EVar "isAfterSeparator") (EFieldAccess (EVar "sp") "trailing"))) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EVar "rest"))) (EIf (EApp (EApp (EVar "isFlagToken") (EVar "sp")) (EVar "t")) (EApp (EApp (EApp (EVar "scanFlag") (EVar "sp")) (EVar "t")) (EVar "rest")) (EIf (EApp (EVar "isRaw") (EFieldAccess (EVar "sp") "trailing")) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit (EVar "t")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "consPositional") (EVar "t")) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isFlagToken" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isFlagToken" ((PVar "sp") (PVar "t")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "t")) (EVar "True") (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-"))) (EVar "t")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 1)))) (EBinOp "||" (EApp (EApp (EVar "isDeclaredShort") (EVar "sp")) (EVar "t")) (EFieldAccess (EVar "sp") "strictDash")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDeclaredShort" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDeclaredShort" ((PVar "sp") (PVar "t")) (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") PWild)) () (EApp (EApp (EVar "declares") (EVar "nm")) (EFieldAccess (EVar "sp") "flags"))) (arm (PCon "None") () (EApp (EApp (EVar "declares") (EVar "t")) (EFieldAccess (EVar "sp") "flags")))))
(DTypeSig false "declares" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyCon "Bool"))))
(DFunDef false "declares" ((PVar "nm") (PVar "fs")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "nm")) (EVar "fs")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "isAfterSeparator" (TyFun (TyCon "Trailing") (TyCon "Bool")))
(DFunDef false "isAfterSeparator" ((PCon "TrailingAfterSeparator")) (EVar "True"))
(DFunDef false "isAfterSeparator" (PWild) (EVar "False"))
(DTypeSig false "isRaw" (TyFun (TyCon "Trailing") (TyCon "Bool")))
(DFunDef false "isRaw" ((PCon "TrailingRaw")) (EVar "True"))
(DFunDef false "isRaw" (PWild) (EVar "False"))
(DTypeSig false "consPositional" (TyFun (TyCon "String") (TyFun (TyCon "Scan") (TyCon "Scan"))))
(DFunDef false "consPositional" ((PVar "t") (PVar "r")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ETuple (EVar "gs") (EBinOp "::" (EVar "t") (EVar "ps")) (EVar "rs")))) (EVar "r")))
(DTypeSig false "consGiven" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Scan") (TyCon "Scan"))))
(DFunDef false "consGiven" ((PVar "g") (PVar "r")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ETuple (EBinOp "::" (EVar "g") (EVar "gs")) (EVar "ps") (EVar "rs")))) (EVar "r")))
(DTypeSig false "scanFlag" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))
(DFunDef false "scanFlag" ((PVar "sp") (PVar "t") (PVar "rest")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "t")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EApp (EApp (EVar "scanKnown") (EVar "sp")) (EVar "t")) (EVar "f")) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EApp (EApp (EApp (EVar "scanEqForm") (EVar "sp")) (EVar "t")) (EVar "nm")) (EVar "v")) (EVar "rest"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest")))))))
(DTypeSig false "scanKnown" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "FlagSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan"))))))
(DFunDef false "scanKnown" ((PVar "sp") (PVar "t") (PVar "f") (PVar "rest")) (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EVar "None"))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest")))) (arm PWild () (EMatch (EVar "rest") (arm (PList) () (EApp (EVar "Err") (EApp (EApp (EVar "missingValueMessage") (EVar "sp")) (EVar "t")))) (arm (PCons (PVar "v") (PVar "rest2")) () (EMatch (EApp (EApp (EApp (EApp (EVar "checkValue") (EVar "sp")) (EVar "t")) (EFieldAccess (EVar "f") "arity")) (EVar "v")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest2"))))))))))
(DTypeSig false "scanEqForm" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))))
(DFunDef false "scanEqForm" ((PVar "sp") (PVar "t") (PVar "nm") (PVar "v") (PVar "rest")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "nm")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest"))) (arm (PCon "Some" (PVar "f")) () (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest"))) (arm PWild () (EMatch (EApp (EApp (EApp (EApp (EVar "checkValue") (EVar "sp")) (EVar "nm")) (EFieldAccess (EVar "f") "arity")) (EVar "v")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))))))))))
(DTypeSig false "scanUnclaimed" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))
(DFunDef false "scanUnclaimed" ((PVar "sp") (PVar "t") (PVar "rest")) (EMatch (EFieldAccess (EVar "sp") "unknown") (arm (PCon "RejectUnknown") () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "t")))) (arm (PCon "CollectUnknown") () (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "nm") (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest")))) (arm (PCon "None") () (EMatch (EVar "rest") (arm (PList) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "t") (EVar "None"))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EListLit)))) (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "t") (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest2"))))))))))
(DTypeSig false "checkValue" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "Arity") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkValue" ((PVar "sp") (PVar "flg") (PCon "OneOf" (PVar "ms") PWild) (PVar "v")) (EIf (EApp (EApp (EVar "hasName") (EVar "v")) (EVar "ms")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "invalidValueMessage") (EVar "sp")) (EVar "flg")) (EVar "v")))))
(DFunDef false "checkValue" ((PVar "sp") (PVar "flg") (PCon "IntValue" PWild) (PVar "v")) (EMatch (EApp (EVar "toInt") (EVar "v")) (arm (PCon "Some" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "invalidValueMessage") (EVar "sp")) (EVar "flg")) (EVar "v"))))))
(DFunDef false "checkValue" (PWild PWild PWild PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DTypeSig false "findFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "Option") (TyCon "FlagSpec")))))
(DFunDef false "findFlag" (PWild (PList)) (EVar "None"))
(DFunDef false "findFlag" ((PVar "nm") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "hasName") (EVar "nm")) (EFieldAccess (EVar "f") "names")) (EApp (EVar "Some") (EVar "f")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findFlag") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasName" (PWild (PList)) (EVar "False"))
(DFunDef false "hasName" ((PVar "nm") (PCons (PVar "n") (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "nm")) (EApp (EApp (EVar "hasName") (EVar "nm")) (EVar "rest"))))
(DTypeSig false "splitEq" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitEq" ((PVar "t")) (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "="))) (EVar "t")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))))))))
(DTypeSig true "flag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyCon "Bool"))))
(DFunDef false "flag" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "hasKey") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "hasKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "hasKey" (PWild (PList)) (EVar "False"))
(DFunDef false "hasKey" ((PVar "nm") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "k") (EVar "nm")) (EApp (EApp (EVar "hasKey") (EVar "nm")) (EVar "rest"))))
(DTypeSig true "flagValue" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "flagValue" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "firstValue") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "firstValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstValue" (PWild (PList)) (EVar "None"))
(DFunDef false "firstValue" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EVar "v") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstValue") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lastValue" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lastValue" ((PVar "nm") (PVar "a")) (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EFieldAccess (EVar "a") "given")) (EVar "None")))
(DTypeSig false "lastValueGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lastValueGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastValueGo" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EVar "rest")) (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EVar "rest")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "flagValues" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "flagValues" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "valuesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "valuesGo" (PWild (PList)) (EListLit))
(DFunDef false "valuesGo" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EMatch (EVar "v") (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (EVar "s") (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "Eq Args discriminates every field" ((pp "v" (TyCon "String"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "Args" ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EApp (EVar "Some") (EVar "v"))))) (fa "positionals" (EListLit (EVar "v"))) (fa "rest" (EListLit))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (ERecordCreate "Args" ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EApp (EVar "Some") (EVar "v"))))) (fa "positionals" (EListLit (EVar "v"))) (fa "rest" (EListLit))))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EVar "None"))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "positionals" (EListLit))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "rest" (EListLit (EVar "v")))))) (EVar "False"))))))
(DProp false "Eq ArgSpec reaches through FlagSpec and Arity" ((pp "n" (TyCon "String"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (DoLet false false (PVar "b") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (EVar "n"))))) (DoLet false false (PVar "c") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--write")))) (ELit (LString "P"))) (EVar "n"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (EBinOp "==" (EBinOp "==" (EVar "a") (EVar "b")) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "a") (EVar "c")) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "a") (EApp (EApp (EVar "spec") (ELit (LString "lint"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (EVar "False"))))))
(DProp false "Debug ArgSpec agrees with Eq" ((pp "n" (TyCon "String"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EVar "a")) (EApp (EVar "debug") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n")))))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EVar "a")) (EApp (EVar "debug") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (EVar "n")))))) (EVar "False"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "indexOf" false) (mem "join" false) (mem "toInt" false) (mem "repeat" false))))
(DData Public "Arity" () ((variant "Switch" (ConPos)) (variant "Value" (ConPos (TyCon "String"))) (variant "ValueList" (ConPos (TyCon "String"))) (variant "OneOf" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "IntValue" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Arity")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Switch") (PCon "Switch")) () (EVar "True")) (arm (PTuple (PCon "Value" (PVar "__a0")) (PCon "Value" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ValueList" (PVar "__a0")) (PCon "ValueList" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "OneOf" (PVar "__a0") (PVar "__a1")) (PCon "OneOf" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "IntValue" (PVar "__a0")) (PCon "IntValue" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Arity")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Switch") () (ELit (LString "Switch"))) (arm (PCon "Value" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Value ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "ValueList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ValueList ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "OneOf" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "OneOf ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "IntValue" (PVar "__a0")) () (EBinOp "++" (ELit (LString "IntValue ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "Visibility" () ((variant "Public" (ConPos)) (variant "Internal" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Visibility")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Public") (PCon "Public")) () (EVar "True")) (arm (PTuple (PCon "Internal") (PCon "Internal")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Visibility")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Public") () (ELit (LString "Public"))) (arm (PCon "Internal") () (ELit (LString "Internal")))))))
(DData Public "Unknown" () ((variant "RejectUnknown" (ConPos)) (variant "CollectUnknown" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Unknown")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RejectUnknown") (PCon "RejectUnknown")) () (EVar "True")) (arm (PTuple (PCon "CollectUnknown") (PCon "CollectUnknown")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Unknown")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RejectUnknown") () (ELit (LString "RejectUnknown"))) (arm (PCon "CollectUnknown") () (ELit (LString "CollectUnknown")))))))
(DData Public "Trailing" () ((variant "TrailingReject" (ConPos)) (variant "TrailingRaw" (ConPos)) (variant "TrailingAfterSeparator" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Trailing")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TrailingReject") (PCon "TrailingReject")) () (EVar "True")) (arm (PTuple (PCon "TrailingRaw") (PCon "TrailingRaw")) () (EVar "True")) (arm (PTuple (PCon "TrailingAfterSeparator") (PCon "TrailingAfterSeparator")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Trailing")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TrailingReject") () (ELit (LString "TrailingReject"))) (arm (PCon "TrailingRaw") () (ELit (LString "TrailingRaw"))) (arm (PCon "TrailingAfterSeparator") () (ELit (LString "TrailingAfterSeparator")))))))
(DData Public "FlagSpec" () ((variant "FlagSpec" (ConNamed (field "names" (TyApp (TyCon "List") (TyCon "String"))) (field "arity" (TyCon "Arity")) (field "summary" (TyCon "String")) (field "visibility" (TyCon "Visibility"))))) ())
(DImpl true "Eq" ((TyCon "FlagSpec")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FlagSpec" ((rf "names" (PVar "__a0")) (rf "arity" (PVar "__a1")) (rf "summary" (PVar "__a2")) (rf "visibility" (PVar "__a3"))) false) (PRec "FlagSpec" ((rf "names" (PVar "__b0")) (rf "arity" (PVar "__b1")) (rf "summary" (PVar "__b2")) (rf "visibility" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FlagSpec")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FlagSpec" ((rf "names" (PVar "__a0")) (rf "arity" (PVar "__a1")) (rf "summary" (PVar "__a2")) (rf "visibility" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FlagSpec {")) (ELit (LString " names = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", arity = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", summary = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", visibility = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "ArgSpec" () ((variant "ArgSpec" (ConNamed (field "verb" (TyCon "String")) (field "flags" (TyApp (TyCon "List") (TyCon "FlagSpec"))) (field "trailing" (TyCon "Trailing")) (field "unknown" (TyCon "Unknown")) (field "strictDash" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "ArgSpec")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ArgSpec" ((rf "verb" (PVar "__a0")) (rf "flags" (PVar "__a1")) (rf "trailing" (PVar "__a2")) (rf "unknown" (PVar "__a3")) (rf "strictDash" (PVar "__a4"))) false) (PRec "ArgSpec" ((rf "verb" (PVar "__b0")) (rf "flags" (PVar "__b1")) (rf "trailing" (PVar "__b2")) (rf "unknown" (PVar "__b3")) (rf "strictDash" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "ArgSpec")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ArgSpec" ((rf "verb" (PVar "__a0")) (rf "flags" (PVar "__a1")) (rf "trailing" (PVar "__a2")) (rf "unknown" (PVar "__a3")) (rf "strictDash" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ArgSpec {")) (ELit (LString " verb = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", flags = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", trailing = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", unknown = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", strictDash = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "Args" () ((variant "Args" (ConNamed (field "given" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) (field "positionals" (TyApp (TyCon "List") (TyCon "String"))) (field "rest" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DImpl true "Eq" ((TyCon "Args")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Args" ((rf "given" (PVar "__a0")) (rf "positionals" (PVar "__a1")) (rf "rest" (PVar "__a2"))) false) (PRec "Args" ((rf "given" (PVar "__b0")) (rf "positionals" (PVar "__b1")) (rf "rest" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "Args")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Args" ((rf "given" (PVar "__a0")) (rf "positionals" (PVar "__a1")) (rf "rest" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Args {")) (ELit (LString " given = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", positionals = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", rest = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "switch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "FlagSpec"))))
(DFunDef false "switch" ((PVar "ns") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EVar "Switch")) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "value" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "value" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "Value") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "valueList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "valueList" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "ValueList") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "oneOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "oneOf" ((PVar "ns") (PVar "ms") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EApp (EVar "OneOf") (EVar "ms")) (EApp (EApp (EVar "join") (ELit (LString "|"))) (EVar "ms")))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "intValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "FlagSpec")))))
(DFunDef false "intValue" ((PVar "ns") (PVar "m") (PVar "s")) (ERecordCreate "FlagSpec" ((fa "names" (EVar "ns")) (fa "arity" (EApp (EVar "IntValue") (EVar "m"))) (fa "summary" (EVar "s")) (fa "visibility" (EVar "Public")))))
(DTypeSig true "internal" (TyFun (TyCon "FlagSpec") (TyCon "FlagSpec")))
(DFunDef false "internal" ((PVar "f")) (ERecordUpdate (EVar "f") ((fa "visibility" (EVar "Internal")))))
(DTypeSig true "spec" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyCon "ArgSpec"))))
(DFunDef false "spec" ((PVar "v") (PVar "fs")) (ERecordCreate "ArgSpec" ((fa "verb" (EVar "v")) (fa "flags" (EVar "fs")) (fa "trailing" (EVar "TrailingReject")) (fa "unknown" (EVar "RejectUnknown")) (fa "strictDash" (EVar "False")))))
(DTypeSig true "withTrailing" (TyFun (TyCon "Trailing") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withTrailing" ((PVar "t") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "trailing" (EVar "t")))))
(DTypeSig true "withUnknown" (TyFun (TyCon "Unknown") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withUnknown" ((PVar "u") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "unknown" (EVar "u")))))
(DTypeSig true "withStrictDash" (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec")))
(DFunDef false "withStrictDash" ((PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "strictDash" (EVar "True")))))
(DTypeSig true "canonical" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "canonical" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "names") (arm (PCons (PVar "n") PWild) () (EVar "n")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "rosterOf" (TyFun (TyCon "ArgSpec") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterOf" ((PVar "sp")) (EApp (EVar "rosterGo") (EFieldAccess (EVar "sp") "flags")))
(DTypeSig false "rosterGo" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterGo" ((PList)) (EListLit))
(DFunDef false "rosterGo" ((PCons (PVar "f") (PVar "rest"))) (EBinOp "++" (EFieldAccess (EVar "f") "names") (EApp (EVar "rosterGo") (EVar "rest"))))
(DTypeSig false "knownSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "knownSet" ((PList)) (ELit (LString "none")))
(DFunDef false "knownSet" ((PVar "ns")) (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "ns")))
(DTypeSig true "unknownFlagMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unknownFlagMessage" ((PVar "sp") (PVar "tok")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": unrecognized flag '"))) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' (known: "))) (EApp (EMethodRef "display") (EApp (EVar "knownSet") (EApp (EVar "rosterOf") (EVar "sp"))))) (ELit (LString ")"))))
(DTypeSig true "missingValueMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "missingValueMessage" ((PVar "sp") (PVar "flg")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "flg"))) (ELit (LString " requires a value"))))
(DTypeSig true "invalidValueMessage" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "invalidValueMessage" ((PVar "sp") (PVar "flg") (PVar "v")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "flg")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EApp (EApp (EVar "arityValueMessage") (EFieldAccess (EVar "sp") "verb")) (EVar "flg")) (EVar "v")) (EFieldAccess (EVar "f") "arity"))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))))
(DTypeSig false "arityValueMessage" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Arity") (TyCon "String"))))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") (PCon "OneOf" (PVar "ms") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "' (known: "))) (EApp (EMethodRef "display") (EApp (EVar "knownSet") (EVar "ms")))) (ELit (LString ")"))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") (PCon "IntValue" PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "flg"))) (ELit (LString ": expected an integer, got '"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))
(DFunDef false "arityValueMessage" ((PVar "vb") (PVar "flg") (PVar "v") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "vb"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "flg"))) (ELit (LString ": unrecognized value '"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))
(DTypeSig true "helpBlockOf" (TyFun (TyCon "ArgSpec") (TyCon "String")))
(DFunDef false "helpBlockOf" ((PVar "sp")) (EBlock (DoLet false false (PVar "pubs") (EApp (EVar "publicFlags") (EFieldAccess (EVar "sp") "flags"))) (DoExpr (EApp (EApp (EVar "helpLines") (EVar "pubs")) (EApp (EApp (EVar "labelWidth") (EVar "pubs")) (ELit (LInt 0)))))))
(DTypeSig true "flagLabel" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "flagLabel" ((PVar "f")) (EBlock (DoLet false false (PVar "ns") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EFieldAccess (EVar "f") "names"))) (DoExpr (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EVar "ns")) (arm (PCon "Value" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "ValueList" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ns"))) (ELit (LString "=<"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "OneOf" PWild (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ">")))) (arm (PCon "IntValue" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ns"))) (ELit (LString " <"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ">"))))))))
(DTypeSig false "publicFlags" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "FlagSpec"))))
(DFunDef false "publicFlags" ((PList)) (EListLit))
(DFunDef false "publicFlags" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EFieldAccess (EVar "f") "visibility") (arm (PCon "Public") () (EBinOp "::" (EVar "f") (EApp (EVar "publicFlags") (EVar "rest")))) (arm (PCon "Internal") () (EApp (EVar "publicFlags") (EVar "rest")))))
(DTypeSig false "labelWidth" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "labelWidth" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "labelWidth" ((PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EApp (EVar "flagLabel") (EVar "f")))) (DoExpr (EApp (EApp (EVar "labelWidth") (EVar "rest")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EVar "acc"))))))
(DTypeSig false "helpLines" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "helpLines" ((PList) PWild) (ELit (LString "")))
(DFunDef false "helpLines" ((PCons (PVar "f") (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "lbl") (EApp (EVar "flagLabel") (EVar "f"))) (DoLet false false (PVar "line") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "lbl"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "repeat") (EBinOp "+" (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "lbl"))) (ELit (LInt 3)))) (ELit (LString " "))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "summary"))) (ELit (LString "")))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (EVar "line")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "helpLines") (EVar "rest")) (EVar "w")))) (ELit (LString ""))))))))
(DTypeSig true "usageExitCode" (TyCon "Int"))
(DFunDef false "usageExitCode" () (ELit (LInt 1)))
(DTypeSig true "parseArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Args")))))
(DFunDef false "parseArgs" ((PVar "sp") (PVar "argv")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ERecordCreate "Args" ((fa "given" (EVar "gs")) (fa "positionals" (EVar "ps")) (fa "rest" (EVar "rs")))))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "argv"))))
(DTypeAlias false "Scan" () (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DTypeSig false "scanArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan"))))
(DFunDef false "scanArgs" (PWild (PList)) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EListLit))))
(DFunDef false "scanArgs" ((PVar "sp") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "t") (ELit (LString "--"))) (EApp (EVar "isAfterSeparator") (EFieldAccess (EVar "sp") "trailing"))) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EVar "rest"))) (EIf (EApp (EApp (EVar "isFlagToken") (EVar "sp")) (EVar "t")) (EApp (EApp (EApp (EVar "scanFlag") (EVar "sp")) (EVar "t")) (EVar "rest")) (EIf (EApp (EVar "isRaw") (EFieldAccess (EVar "sp") "trailing")) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit (EVar "t")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "consPositional") (EVar "t")) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isFlagToken" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isFlagToken" ((PVar "sp") (PVar "t")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "t")) (EVar "True") (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-"))) (EVar "t")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 1)))) (EBinOp "||" (EApp (EApp (EVar "isDeclaredShort") (EVar "sp")) (EVar "t")) (EFieldAccess (EVar "sp") "strictDash")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDeclaredShort" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDeclaredShort" ((PVar "sp") (PVar "t")) (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") PWild)) () (EApp (EApp (EVar "declares") (EVar "nm")) (EFieldAccess (EVar "sp") "flags"))) (arm (PCon "None") () (EApp (EApp (EVar "declares") (EVar "t")) (EFieldAccess (EVar "sp") "flags")))))
(DTypeSig false "declares" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyCon "Bool"))))
(DFunDef false "declares" ((PVar "nm") (PVar "fs")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "nm")) (EVar "fs")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "isAfterSeparator" (TyFun (TyCon "Trailing") (TyCon "Bool")))
(DFunDef false "isAfterSeparator" ((PCon "TrailingAfterSeparator")) (EVar "True"))
(DFunDef false "isAfterSeparator" (PWild) (EVar "False"))
(DTypeSig false "isRaw" (TyFun (TyCon "Trailing") (TyCon "Bool")))
(DFunDef false "isRaw" ((PCon "TrailingRaw")) (EVar "True"))
(DFunDef false "isRaw" (PWild) (EVar "False"))
(DTypeSig false "consPositional" (TyFun (TyCon "String") (TyFun (TyCon "Scan") (TyCon "Scan"))))
(DFunDef false "consPositional" ((PVar "t") (PVar "r")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ETuple (EVar "gs") (EBinOp "::" (EVar "t") (EVar "ps")) (EVar "rs")))) (EVar "r")))
(DTypeSig false "consGiven" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Scan") (TyCon "Scan"))))
(DFunDef false "consGiven" ((PVar "g") (PVar "r")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "gs") (PVar "ps") (PVar "rs"))) (ETuple (EBinOp "::" (EVar "g") (EVar "gs")) (EVar "ps") (EVar "rs")))) (EVar "r")))
(DTypeSig false "scanFlag" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))
(DFunDef false "scanFlag" ((PVar "sp") (PVar "t") (PVar "rest")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "t")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EApp (EApp (EVar "scanKnown") (EVar "sp")) (EVar "t")) (EVar "f")) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EApp (EApp (EApp (EVar "scanEqForm") (EVar "sp")) (EVar "t")) (EVar "nm")) (EVar "v")) (EVar "rest"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest")))))))
(DTypeSig false "scanKnown" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "FlagSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan"))))))
(DFunDef false "scanKnown" ((PVar "sp") (PVar "t") (PVar "f") (PVar "rest")) (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EVar "None"))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest")))) (arm PWild () (EMatch (EVar "rest") (arm (PList) () (EApp (EVar "Err") (EApp (EApp (EVar "missingValueMessage") (EVar "sp")) (EVar "t")))) (arm (PCons (PVar "v") (PVar "rest2")) () (EMatch (EApp (EApp (EApp (EApp (EVar "checkValue") (EVar "sp")) (EVar "t")) (EFieldAccess (EVar "f") "arity")) (EVar "v")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest2"))))))))))
(DTypeSig false "scanEqForm" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))))
(DFunDef false "scanEqForm" ((PVar "sp") (PVar "t") (PVar "nm") (PVar "v") (PVar "rest")) (EMatch (EApp (EApp (EVar "findFlag") (EVar "nm")) (EFieldAccess (EVar "sp") "flags")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest"))) (arm (PCon "Some" (PVar "f")) () (EMatch (EFieldAccess (EVar "f") "arity") (arm (PCon "Switch") () (EApp (EApp (EApp (EVar "scanUnclaimed") (EVar "sp")) (EVar "t")) (EVar "rest"))) (arm PWild () (EMatch (EApp (EApp (EApp (EApp (EVar "checkValue") (EVar "sp")) (EVar "nm")) (EFieldAccess (EVar "f") "arity")) (EVar "v")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "consGiven") (ETuple (EApp (EVar "canonical") (EVar "f")) (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))))))))))
(DTypeSig false "scanUnclaimed" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scan")))))
(DFunDef false "scanUnclaimed" ((PVar "sp") (PVar "t") (PVar "rest")) (EMatch (EFieldAccess (EVar "sp") "unknown") (arm (PCon "RejectUnknown") () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "t")))) (arm (PCon "CollectUnknown") () (EMatch (EApp (EVar "splitEq") (EVar "t")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "nm") (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest")))) (arm (PCon "None") () (EMatch (EVar "rest") (arm (PList) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "t") (EVar "None"))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EListLit)))) (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EVar "consGiven") (ETuple (EVar "t") (EApp (EVar "Some") (EVar "v")))) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest2"))))))))))
(DTypeSig false "checkValue" (TyFun (TyCon "ArgSpec") (TyFun (TyCon "String") (TyFun (TyCon "Arity") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkValue" ((PVar "sp") (PVar "flg") (PCon "OneOf" (PVar "ms") PWild) (PVar "v")) (EIf (EApp (EApp (EVar "hasName") (EVar "v")) (EVar "ms")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "invalidValueMessage") (EVar "sp")) (EVar "flg")) (EVar "v")))))
(DFunDef false "checkValue" ((PVar "sp") (PVar "flg") (PCon "IntValue" PWild) (PVar "v")) (EMatch (EApp (EVar "toInt") (EVar "v")) (arm (PCon "Some" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "invalidValueMessage") (EVar "sp")) (EVar "flg")) (EVar "v"))))))
(DFunDef false "checkValue" (PWild PWild PWild PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DTypeSig false "findFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "Option") (TyCon "FlagSpec")))))
(DFunDef false "findFlag" (PWild (PList)) (EVar "None"))
(DFunDef false "findFlag" ((PVar "nm") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "hasName") (EVar "nm")) (EFieldAccess (EVar "f") "names")) (EApp (EVar "Some") (EVar "f")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findFlag") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasName" (PWild (PList)) (EVar "False"))
(DFunDef false "hasName" ((PVar "nm") (PCons (PVar "n") (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "nm")) (EApp (EApp (EVar "hasName") (EVar "nm")) (EVar "rest"))))
(DTypeSig false "splitEq" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitEq" ((PVar "t")) (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "="))) (EVar "t")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))))))))
(DTypeSig true "flag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyCon "Bool"))))
(DFunDef false "flag" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "hasKey") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "hasKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "hasKey" (PWild (PList)) (EVar "False"))
(DFunDef false "hasKey" ((PVar "nm") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "k") (EVar "nm")) (EApp (EApp (EVar "hasKey") (EVar "nm")) (EVar "rest"))))
(DTypeSig true "flagValue" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "flagValue" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "firstValue") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "firstValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstValue" (PWild (PList)) (EVar "None"))
(DFunDef false "firstValue" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EVar "v") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstValue") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lastValue" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lastValue" ((PVar "nm") (PVar "a")) (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EFieldAccess (EVar "a") "given")) (EVar "None")))
(DTypeSig false "lastValueGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lastValueGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastValueGo" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EVar "rest")) (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lastValueGo") (EVar "nm")) (EVar "rest")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "flagValues" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "flagValues" ((PVar "nm") (PVar "a")) (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EFieldAccess (EVar "a") "given")))
(DTypeSig false "valuesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "valuesGo" (PWild (PList)) (EListLit))
(DFunDef false "valuesGo" ((PVar "nm") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "nm")) (EMatch (EVar "v") (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (EVar "s") (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "valuesGo") (EVar "nm")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "Eq Args discriminates every field" ((pp "v" (TyCon "String"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "Args" ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EApp (EVar "Some") (EVar "v"))))) (fa "positionals" (EListLit (EVar "v"))) (fa "rest" (EListLit))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (ERecordCreate "Args" ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EApp (EVar "Some") (EVar "v"))))) (fa "positionals" (EListLit (EVar "v"))) (fa "rest" (EListLit))))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "given" (EListLit (ETuple (ELit (LString "--out")) (EVar "None"))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "positionals" (EListLit))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "Args" (EVar "base") ((fa "rest" (EListLit (EVar "v")))))) (EVar "False"))))))
(DProp false "Eq ArgSpec reaches through FlagSpec and Arity" ((pp "n" (TyCon "String"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (DoLet false false (PVar "b") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (EVar "n"))))) (DoLet false false (PVar "c") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--write")))) (ELit (LString "P"))) (EVar "n"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (EBinOp "==" (EBinOp "==" (EVar "a") (EVar "b")) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "a") (EVar "c")) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "a") (EApp (EApp (EVar "spec") (ELit (LString "lint"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (EVar "False"))))))
(DProp false "Debug ArgSpec agrees with Eq" ((pp "n" (TyCon "String"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n"))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "a")) (EApp (EMethodRef "debug") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")))) (EVar "n")))))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "a")) (EApp (EMethodRef "debug") (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (EVar "n")))))) (EVar "False"))))))
