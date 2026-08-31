# META
source_lines=584
stages=DESUGAR,MARK
# SOURCE
-- args.mdk — one command-line argument parser, as a first-order value
--
-- Design notes
-- ────────────
-- See `docs/design/ARGS-DESIGN.md` for the decision and the rejected shapes.
-- The one-line version: a flag specification is a VALUE (`List FlagSpec`
-- inside an `ArgSpec`), never a combinator tree.  `rosterOf`, `helpBlockOf`,
-- `unknownFlagMessage` and `parseArgs` are four renderings of that one value,
-- so a verb's help text, its `(known: …)` set and what it actually parses
-- cannot drift apart — that drift is the defect this module exists to close.
--
-- Why not an `optparse-applicative`-style free applicative: it needs
-- existential quantification and Medaka has none (probed — the `b` in
-- `PAp (P (b -> a)) (P b)` is a rigid, scope-escaping type variable, not an
-- existential).  The only expressible combinator shape is the wrapped-function
-- one, which is opaque and therefore cannot derive help.
--
-- Cost posture: `FlagSpec` is four immutable fields of plain data.  There are
-- deliberately NO `deriving` clauses and NO `impl`s on the types below, and
-- the module imports only `string` — every consumer already imports it, so
-- nothing new enters dispatch scope.  Per-flag lookup over `given` is a
-- monomorphic fold rather than a polymorphic `lookup`.  Adding an `impl`, a
-- `deriving`, or a `map`/`hash_map` import invalidates the measured import
-- cost and must be re-measured (`[T-STDLIB-IMPORT]`).
--
-- Wording: the four rejection sentences are the ratified ones from
-- `docs/ops/CLI-CONFORMANCE.md` (C2 unknown flag, C3 exit code 1).  They are
-- rendered here and nowhere else.

import string.{startsWith, indexOf, join, toInt, repeat}

-- ── The specification ──────────────────────────────────────────────────────

{- | What a flag does with the token that follows it.

   `Switch` takes no value.  `Value`/`ValueList`/`OneOf`/`IntValue` all take
   one, in either C1 spelling (`--flag v` or `--flag=v`).  The trailing
   `String` on each value-taking arm is the help METAVAR (`PATH`, `N`, …);
   `OneOf` additionally carries the closed set its value must belong to, and
   `IntValue` requires the value to parse as an integer.

   `ValueList` differs from `Value` only in how it renders in help
   (`--flag=<A,B>`) — splitting the comma list is the consumer's business. -}
public export data Arity =
  | Switch
  | Value String
  | ValueList String
  | OneOf (List String) String
  | IntValue String

-- | Whether a flag appears in `helpBlockOf`.  Both kinds appear in `rosterOf`.
public export data Visibility = Public | Internal

{- | What happens to a `--`-shaped token that no `FlagSpec` claims.

   `RejectUnknown` is the C2 default.  `CollectUnknown` exists for `codemod`,
   whose flag vocabulary is per-codemod and therefore not statically knowable:
   an unclaimed token is recorded in `given`, consuming the following token as
   its value. -}
public export data Unknown = RejectUnknown | CollectUnknown

{- | How the verb treats a raw trailing section.

   * `TrailingReject` — there is none.  `--` is not special and falls to the
     unknown-flag path like any other `--`-shaped token.
   * `TrailingRaw` — the FIRST positional ends flag scanning; everything after
     it is the callee's argv, `--` included and NOT consumed (`medaka run`).
   * `TrailingAfterSeparator` — the first bare `--` is consumed as a
     separator and everything after it lands in `rest`. -}
public export data Trailing =
  | TrailingReject
  | TrailingRaw
  | TrailingAfterSeparator

{- | One flag, with every spelling it answers to.

   `names` carries complete tokens including their dashes, longest-canonical
   first: `["--write", "-w"]`.  The head is the CANONICAL name — the key
   `parseArgs` records in `Args.given` and the one `flag`/`flagValue` query
   by, whichever spelling the user typed. -}
public export data FlagSpec =
  | FlagSpec {
      names : List String,
      arity : Arity,
      summary : String,
      visibility : Visibility,
    }

-- | One verb's whole argument vocabulary.  This is the value everything else
--   in this module is a rendering of.
public export data ArgSpec =
  | ArgSpec {
      verb : String,
      flags : List FlagSpec,
      trailing : Trailing,
      unknown : Unknown,
    }

{- | The result of a successful parse.

   `given` keeps argv order, so a verb that wants first-occurrence semantics
   calls `flagValue` and one that wants last-occurrence calls `lastValue` —
   the tree contains both conventions and this module deliberately picks
   neither for you. -}
public export data Args =
  | Args {
      given : List (String, Option String),
      positionals : List String,
      rest : List String,
    }

-- ── Building a spec ────────────────────────────────────────────────────────

{- | A flag taking no value.

   > canonical (switch ["--write", "-w"] "rewrite in place")
   "--write" -}
export
switch : List String -> String -> FlagSpec
switch ns s =
  FlagSpec { names = ns, arity = Switch, summary = s, visibility = Public }

{- | A flag taking one value, with a help metavar.

   > flagLabel (value ["--out", "-o"] "PATH" "where to write")
   "--out, -o <PATH>" -}
export
value : List String -> String -> String -> FlagSpec
value ns m s =
  FlagSpec { names = ns, arity = Value m, summary = s, visibility = Public }

{- | A flag whose value is a comma-separated list.  Renders as `--flag=<M>` in
     help; the split itself is the consumer's business.

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

{- | A flag whose value must be a member of a closed set.  The metavar is the
     set itself, so help and the rejection sentence stay in step.

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

{- | A flag whose value must parse as an integer.

   > flagLabel (intValue ["--jobs"] "N" "worker count")
   "--jobs <N>" -}
export
intValue : List String -> String -> String -> FlagSpec
intValue ns m s =
  FlagSpec { names = ns, arity = IntValue m, summary = s, visibility = Public }

{- | Hide a flag from `helpBlockOf`.  It stays in `rosterOf` and stays
     parseable — an internal flag the rejection sentence refused to name would
     be a worse lie than one help omits.

   > helpBlockOf (spec "check" [internal (switch ["--allow-internal"] "x")])
   "" -}
export
internal : FlagSpec -> FlagSpec
internal f = { f | visibility = Internal }

{- | A verb's spec with the conservative defaults: no trailing section,
     unknown flags rejected.

   > rosterOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place"])
   ["--write"] -}
export
spec : String -> List FlagSpec -> ArgSpec
spec v fs = ArgSpec {
  verb = v,
  flags = fs,
  trailing = TrailingReject,
  unknown = RejectUnknown,
}

-- | Give a spec a trailing-section policy.
export
withTrailing : Trailing -> ArgSpec -> ArgSpec
withTrailing t sp = { sp | trailing = t }

-- | Give a spec an unknown-token policy.
export
withUnknown : Unknown -> ArgSpec -> ArgSpec
withUnknown u sp = { sp | unknown = u }

-- ── Renderings of the spec ─────────────────────────────────────────────────

{- | The head of `names` — the key `parseArgs` records whichever spelling was
     typed.

   > canonical (switch ["-w"] "rewrite in place")
   "-w" -}
export
canonical : FlagSpec -> String
canonical f = match f.names
  n::_ => n
  [] => ""

{- | The `(known: …)` set, in declaration order.

   🚨 Filtered to `--`-prefixed names ONLY.  `names` carries short spellings
   from the first day, but widening this rendering changes the `(known: …)`
   text of every verb with a short flag, so it happens once, deliberately, as
   its own change — not as a side effect of a migration.

   > rosterOf (spec "run" [switch ["--json"] "j", switch ["--release", "-r"] "r"])
   ["--json", "--release"] -}
export
rosterOf : ArgSpec -> List String
rosterOf sp = rosterGo sp.flags

rosterGo : List FlagSpec -> List String
rosterGo [] = []
rosterGo (f::rest) = longNames f.names ++ rosterGo rest

longNames : List String -> List String
longNames [] = []
longNames (n::rest)
  | startsWith "--" n = n :: longNames rest
  | otherwise = longNames rest

-- | Render a name set the way every rejection sentence does: a verb with no
--   flags at all says `none`, not an empty parenthesis.
knownSet : List String -> String
knownSet [] = "none"
knownSet ns = join ", " ns

{- | The ratified C2 sentence (`docs/ops/CLI-CONFORMANCE.md` §2), rendered in
     exactly one place.

   > unknownFlagMessage (spec "fmt" [switch ["--write", "-w"] "w"]) "--zzz"
   "medaka fmt: unrecognized flag '--zzz' (known: --write)"
   > unknownFlagMessage (spec "doc" []) "--zzz"
   "medaka doc: unrecognized flag '--zzz' (known: none)" -}
export
unknownFlagMessage : ArgSpec -> String -> String
unknownFlagMessage sp tok = "medaka \{sp.verb}: unrecognized flag '\{tok}' (known: \{knownSet (rosterOf sp)})"

{- | The ratified missing-value sentence.  `flg` is the token as the user
     spelled it, not the canonical name.

   > missingValueMessage (spec "build" [value ["-o"] "PATH" "out"]) "-o"
   "medaka build: -o requires a value" -}
export
missingValueMessage : ArgSpec -> String -> String
missingValueMessage sp flg = "medaka \{sp.verb}: \{flg} requires a value"

{- | C2's shape one level down: the flag was recognized, its VALUE was not.
     `OneOf` names the set the same way C2 names the flag set; `IntValue` says
     what it wanted.

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

{- | The flag half of a `--help` block: two columns, `Internal` flags omitted,
     no trailing newline.  A spec with no public flags renders `""`.

   > helpBlockOf (spec "fmt" [switch ["--write", "-w"] "rewrite in place", value ["--out"] "PATH" "where to write"])
   "  --write, -w    rewrite in place\n  --out <PATH>   where to write" -}
export
helpBlockOf : ArgSpec -> String
helpBlockOf sp =
  let pubs = publicFlags sp.flags
  helpLines pubs (labelWidth pubs 0)

{- | The left column of one help row: every spelling, then the metavar.

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
publicFlags (f::rest) = match f.visibility
  Public => f :: publicFlags rest
  Internal => publicFlags rest

labelWidth : List FlagSpec -> Int -> Int
labelWidth [] acc = acc
labelWidth (f::rest) acc =
  let n = stringLength (flagLabel f)
  labelWidth rest (max n acc)

helpLines : List FlagSpec -> Int -> String
helpLines [] _ = ""
helpLines (f::rest) w =
  let lbl = flagLabel f
  let line = "  \{lbl}\{repeat (w - stringLength lbl + 3) " "}\{f.summary}"
  match rest
    [] => line
    _ => "\{line}\n\{helpLines rest w}"

{- | The C3 exit code for every usage error this module can report — one
     number, so a verb never has to decide.

   > usageExitCode
   1 -}
export
usageExitCode : Int
usageExitCode = 1

-- ── Parsing ────────────────────────────────────────────────────────────────

{- | Parse argv against a spec.  `Err` carries the finished sentence, ready
     for stderr; the caller exits `usageExitCode`.

   A known switch, then the same flag by its short spelling:

   > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--write"])
   Ok True
   > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["-w"])
   Ok True

   C1 — both value spellings reach the same canonical key:

   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out", "x"])
   Ok Some "x"
   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["--out=x"])
   Ok Some "x"
   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o", "x"])
   Ok Some "x"
   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out", "-o"] "PATH" "o"]) ["-o=x"])
   Ok Some "x"

   C2 — an unclaimed `--`-shaped token, and a value flag with nothing after it:

   > map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) ["--zzz"])
   Err "medaka fmt: unrecognized flag '--zzz' (known: --write)"
   > map (_ => "ok") (parseArgs (spec "fmt" [value ["--out"] "PATH" "o"]) ["--out"])
   Err "medaka fmt: --out requires a value"

   Positionals, in order, unclaimed by any flag:

   > map (a => a.positionals) (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["a.mdk", "--write", "b.mdk"])
   Ok ["a.mdk", "b.mdk"]

   `OneOf` and `IntValue` check the value they took, in either spelling, and
   render C2's shape one level down when it does not belong:

   > map (a => flagValue "--engine" a) (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine", "native"])
   Ok Some "native"
   > map (_ => "ok") (parseArgs (spec "test" [oneOf ["--engine"] ["eval", "native"] "e"]) ["--engine=zzz"])
   Err "medaka test: --engine: unrecognized value 'zzz' (known: eval, native)"
   > map (a => flagValue "--jobs" a) (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "-3"])
   Ok Some "-3"
   > map (_ => "ok") (parseArgs (spec "gate" [intValue ["--jobs"] "N" "j"]) ["--jobs", "x"])
   Err "medaka gate: --jobs: expected an integer, got 'x'"

   `TrailingReject` (the default) gives `--` no meaning, so it rejects like
   any other unclaimed token:

   > map (_ => "ok") (parseArgs (spec "fmt" [switch ["--write"] "w"]) ["--"])
   Err "medaka fmt: unrecognized flag '--' (known: --write)"

   `TrailingRaw` ends the scan at the first positional; a literal `--` after
   it reaches the callee UNCONSUMED, and so does a `--`-shaped token the spec
   never heard of:

   > map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["p.mdk", "--", "--foo"])
   Ok ["--", "--foo"]
   > map (a => a.rest) (parseArgs (withTrailing TrailingRaw (spec "run" [switch ["--json"] "j"])) ["--json", "p.mdk", "--zzz"])
   Ok ["--zzz"]

   `TrailingAfterSeparator` consumes exactly ONE `--`; a second one is data:

   > map (a => a.rest) (parseArgs (withTrailing TrailingAfterSeparator (spec "gate" [switch ["--json"] "j"])) ["--json", "--", "--x", "--"])
   Ok ["--x", "--"]

   `CollectUnknown` records a token no `FlagSpec` claims, for the one verb
   (`codemod`) whose vocabulary is not statically knowable:

   > map (a => flagValue "--anything" a) (parseArgs (withUnknown CollectUnknown (spec "codemod" [])) ["--anything", "v"])
   Ok Some "v" -}
export
parseArgs : ArgSpec -> List String -> Result String Args
parseArgs sp argv = map
  ((gs, ps, rs) => Args { given = gs, positionals = ps, rest = rs })
  (scanArgs sp argv)

-- The scanner's carrier: the three `Args` fields, still being built, or the
-- finished rejection sentence.
type Scan = Result String (List (String, Option String), List String, List String)

-- The scanner.  Returns the three `Args` fields in argv order, so nothing is
-- accumulated backwards and nothing has to be reversed.
scanArgs : ArgSpec -> List String -> Scan
scanArgs _ [] = Ok ([], [], [])
scanArgs sp (t::rest)
  | t == "--" && isAfterSeparator sp.trailing = Ok ([], [], rest)
  | isFlagToken t = scanFlag sp t rest
  | isRaw sp.trailing = Ok ([], [t], rest)
  | otherwise = consPositional t (scanArgs sp rest)

-- A `-`-shaped token: `-` alone is a conventional stdin/stdout placeholder and
-- is a positional, but `--` is not — under `TrailingReject`/`TrailingRaw` it
-- has no meaning, and falling here is what makes it reject like any other
-- unclaimed token.
isFlagToken : String -> Bool
isFlagToken t = startsWith "-" t && stringLength t > 1

isAfterSeparator : Trailing -> Bool
isAfterSeparator TrailingAfterSeparator = True
isAfterSeparator _ = False

isRaw : Trailing -> Bool
isRaw TrailingRaw = True
isRaw _ = False

consPositional : String -> Scan -> Scan
consPositional t r = map ((gs, ps, rs) => (gs, t::ps, rs)) r

consGiven : (String, Option String) -> Scan -> Scan
consGiven g r = map ((gs, ps, rs) => (g::gs, ps, rs)) r

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
    v::rest2 => match checkValue sp t f.arity v
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
      v::rest2 => consGiven (t, Some v) (scanArgs sp rest2)

checkValue : ArgSpec -> String -> Arity -> String -> Result String Unit
checkValue sp flg (OneOf ms _) v =
  if hasName v ms then
    Ok ()
  else
    Err (invalidValueMessage sp flg v)
checkValue sp flg (IntValue _) v = match toInt v
  Some _ => Ok ()
  None => Err (invalidValueMessage sp flg v)
checkValue _ _ _ _ = Ok ()

findFlag : String -> List FlagSpec -> Option FlagSpec
findFlag _ [] = None
findFlag nm (f::rest)
  | hasName nm f.names = Some f
  | otherwise = findFlag nm rest

hasName : String -> List String -> Bool
hasName _ [] = False
hasName nm (n::rest) = n == nm || hasName nm rest

-- `--flag=v` → `("--flag", "v")`.  An `=` at position 0 is not a split.
splitEq : String -> Option (String, String)
splitEq t = match indexOf "=" t
  None => None
  Some i =>
    if i <= 0 then
      None
    else
      Some (stringSlice 0 i t, stringSlice (i + 1) (stringLength t) t)

-- ── Querying the parse ─────────────────────────────────────────────────────
-- All four query by the CANONICAL name (the head of the flag's `names`),
-- whichever spelling the user typed.

{- | Was this flag given at all?

   > map (a => flag "--write" a) (parseArgs (spec "fmt" [switch ["--write", "-w"] "w"]) [])
   Ok False -}
export
flag : String -> Args -> Bool
flag nm a = hasKey nm a.given

hasKey : String -> List (String, Option String) -> Bool
hasKey _ [] = False
hasKey nm ((k, _)::rest) = k == nm || hasKey nm rest

{- | The FIRST occurrence's value.

   > map (a => flagValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok Some "a" -}
export
flagValue : String -> Args -> Option String
flagValue nm a = firstValue nm a.given

firstValue : String -> List (String, Option String) -> Option String
firstValue _ [] = None
firstValue nm ((k, v)::rest)
  | k == nm = v
  | otherwise = firstValue nm rest

{- | The LAST occurrence's value.  Both conventions live in the tree; the
     verb picks.

   > map (a => lastValue "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok Some "b" -}
export
lastValue : String -> Args -> Option String
lastValue nm a = lastValueGo nm a.given None

lastValueGo : String -> List (String, Option String) -> Option String -> Option String
lastValueGo _ [] acc = acc
lastValueGo nm ((k, v)::rest) acc
  | k == nm = lastValueGo nm rest v
  | otherwise = lastValueGo nm rest acc

{- | Every occurrence's value, in argv order.

   > map (a => flagValues "--out" a) (parseArgs (spec "fmt" [value ["--out"] "P" "o"]) ["--out", "a", "--out", "b"])
   Ok ["a", "b"] -}
export
flagValues : String -> Args -> List String
flagValues nm a = valuesGo nm a.given

valuesGo : String -> List (String, Option String) -> List String
valuesGo _ [] = []
valuesGo nm ((k, v)::rest)
  | k == nm = match v
    Some s => s :: valuesGo nm rest
    None => valuesGo nm rest
  | otherwise = valuesGo nm rest
# DESUGAR
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "indexOf" false) (mem "join" false) (mem "toInt" false) (mem "repeat" false))))
(DData Public "Arity" () ((variant "Switch" (ConPos)) (variant "Value" (ConPos (TyCon "String"))) (variant "ValueList" (ConPos (TyCon "String"))) (variant "OneOf" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "IntValue" (ConPos (TyCon "String")))) ())
(DData Public "Visibility" () ((variant "Public" (ConPos)) (variant "Internal" (ConPos))) ())
(DData Public "Unknown" () ((variant "RejectUnknown" (ConPos)) (variant "CollectUnknown" (ConPos))) ())
(DData Public "Trailing" () ((variant "TrailingReject" (ConPos)) (variant "TrailingRaw" (ConPos)) (variant "TrailingAfterSeparator" (ConPos))) ())
(DData Public "FlagSpec" () ((variant "FlagSpec" (ConNamed (field "names" (TyApp (TyCon "List") (TyCon "String"))) (field "arity" (TyCon "Arity")) (field "summary" (TyCon "String")) (field "visibility" (TyCon "Visibility"))))) ())
(DData Public "ArgSpec" () ((variant "ArgSpec" (ConNamed (field "verb" (TyCon "String")) (field "flags" (TyApp (TyCon "List") (TyCon "FlagSpec"))) (field "trailing" (TyCon "Trailing")) (field "unknown" (TyCon "Unknown"))))) ())
(DData Public "Args" () ((variant "Args" (ConNamed (field "given" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) (field "positionals" (TyApp (TyCon "List") (TyCon "String"))) (field "rest" (TyApp (TyCon "List") (TyCon "String")))))) ())
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
(DFunDef false "spec" ((PVar "v") (PVar "fs")) (ERecordCreate "ArgSpec" ((fa "verb" (EVar "v")) (fa "flags" (EVar "fs")) (fa "trailing" (EVar "TrailingReject")) (fa "unknown" (EVar "RejectUnknown")))))
(DTypeSig true "withTrailing" (TyFun (TyCon "Trailing") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withTrailing" ((PVar "t") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "trailing" (EVar "t")))))
(DTypeSig true "withUnknown" (TyFun (TyCon "Unknown") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withUnknown" ((PVar "u") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "unknown" (EVar "u")))))
(DTypeSig true "canonical" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "canonical" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "names") (arm (PCons (PVar "n") PWild) () (EVar "n")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "rosterOf" (TyFun (TyCon "ArgSpec") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterOf" ((PVar "sp")) (EApp (EVar "rosterGo") (EFieldAccess (EVar "sp") "flags")))
(DTypeSig false "rosterGo" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterGo" ((PList)) (EListLit))
(DFunDef false "rosterGo" ((PCons (PVar "f") (PVar "rest"))) (EBinOp "++" (EApp (EVar "longNames") (EFieldAccess (EVar "f") "names")) (EApp (EVar "rosterGo") (EVar "rest"))))
(DTypeSig false "longNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "longNames" ((PList)) (EListLit))
(DFunDef false "longNames" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "n")) (EBinOp "::" (EVar "n") (EApp (EVar "longNames") (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "longNames") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DFunDef false "scanArgs" ((PVar "sp") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "t") (ELit (LString "--"))) (EApp (EVar "isAfterSeparator") (EFieldAccess (EVar "sp") "trailing"))) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EVar "rest"))) (EIf (EApp (EVar "isFlagToken") (EVar "t")) (EApp (EApp (EApp (EVar "scanFlag") (EVar "sp")) (EVar "t")) (EVar "rest")) (EIf (EApp (EVar "isRaw") (EFieldAccess (EVar "sp") "trailing")) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit (EVar "t")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "consPositional") (EVar "t")) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isFlagToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isFlagToken" ((PVar "t")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-"))) (EVar "t")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 1)))))
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
# MARK
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "indexOf" false) (mem "join" false) (mem "toInt" false) (mem "repeat" false))))
(DData Public "Arity" () ((variant "Switch" (ConPos)) (variant "Value" (ConPos (TyCon "String"))) (variant "ValueList" (ConPos (TyCon "String"))) (variant "OneOf" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "IntValue" (ConPos (TyCon "String")))) ())
(DData Public "Visibility" () ((variant "Public" (ConPos)) (variant "Internal" (ConPos))) ())
(DData Public "Unknown" () ((variant "RejectUnknown" (ConPos)) (variant "CollectUnknown" (ConPos))) ())
(DData Public "Trailing" () ((variant "TrailingReject" (ConPos)) (variant "TrailingRaw" (ConPos)) (variant "TrailingAfterSeparator" (ConPos))) ())
(DData Public "FlagSpec" () ((variant "FlagSpec" (ConNamed (field "names" (TyApp (TyCon "List") (TyCon "String"))) (field "arity" (TyCon "Arity")) (field "summary" (TyCon "String")) (field "visibility" (TyCon "Visibility"))))) ())
(DData Public "ArgSpec" () ((variant "ArgSpec" (ConNamed (field "verb" (TyCon "String")) (field "flags" (TyApp (TyCon "List") (TyCon "FlagSpec"))) (field "trailing" (TyCon "Trailing")) (field "unknown" (TyCon "Unknown"))))) ())
(DData Public "Args" () ((variant "Args" (ConNamed (field "given" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) (field "positionals" (TyApp (TyCon "List") (TyCon "String"))) (field "rest" (TyApp (TyCon "List") (TyCon "String")))))) ())
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
(DFunDef false "spec" ((PVar "v") (PVar "fs")) (ERecordCreate "ArgSpec" ((fa "verb" (EVar "v")) (fa "flags" (EVar "fs")) (fa "trailing" (EVar "TrailingReject")) (fa "unknown" (EVar "RejectUnknown")))))
(DTypeSig true "withTrailing" (TyFun (TyCon "Trailing") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withTrailing" ((PVar "t") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "trailing" (EVar "t")))))
(DTypeSig true "withUnknown" (TyFun (TyCon "Unknown") (TyFun (TyCon "ArgSpec") (TyCon "ArgSpec"))))
(DFunDef false "withUnknown" ((PVar "u") (PVar "sp")) (ERecordUpdate (EVar "sp") ((fa "unknown" (EVar "u")))))
(DTypeSig true "canonical" (TyFun (TyCon "FlagSpec") (TyCon "String")))
(DFunDef false "canonical" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "names") (arm (PCons (PVar "n") PWild) () (EVar "n")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "rosterOf" (TyFun (TyCon "ArgSpec") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterOf" ((PVar "sp")) (EApp (EVar "rosterGo") (EFieldAccess (EVar "sp") "flags")))
(DTypeSig false "rosterGo" (TyFun (TyApp (TyCon "List") (TyCon "FlagSpec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rosterGo" ((PList)) (EListLit))
(DFunDef false "rosterGo" ((PCons (PVar "f") (PVar "rest"))) (EBinOp "++" (EApp (EVar "longNames") (EFieldAccess (EVar "f") "names")) (EApp (EVar "rosterGo") (EVar "rest"))))
(DTypeSig false "longNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "longNames" ((PList)) (EListLit))
(DFunDef false "longNames" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "n")) (EBinOp "::" (EVar "n") (EApp (EVar "longNames") (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "longNames") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DFunDef false "scanArgs" ((PVar "sp") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "t") (ELit (LString "--"))) (EApp (EVar "isAfterSeparator") (EFieldAccess (EVar "sp") "trailing"))) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit) (EVar "rest"))) (EIf (EApp (EVar "isFlagToken") (EVar "t")) (EApp (EApp (EApp (EVar "scanFlag") (EVar "sp")) (EVar "t")) (EVar "rest")) (EIf (EApp (EVar "isRaw") (EFieldAccess (EVar "sp") "trailing")) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit (EVar "t")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "consPositional") (EVar "t")) (EApp (EApp (EVar "scanArgs") (EVar "sp")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isFlagToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isFlagToken" ((PVar "t")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-"))) (EVar "t")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 1)))))
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
