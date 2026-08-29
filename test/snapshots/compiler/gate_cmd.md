# META
source_lines=1070
stages=DESUGAR,MARK
# SOURCE
{- gate_cmd.mdk — `medaka gate`, the gate-registry driver (#2176, epic #2182).

   Two commands so far: `medaka gate list [<selector>...] [--json]` (the read
   path — the registry schema `test/gates.toml`, a reader for it, and the
   selector language) and `medaka gate run [<selector>...]`, which EXECUTES the
   selected gates.  `verify` and `explain`
   (docs/ops/GATE-REGISTRY-DESIGN.md §3) are later slices; they are rejected
   here with a message that says so rather than silently doing nothing.

   ⚠️ `gate run` is a NEW WAY TO INVOKE a gate script, not a new way for a gate
   to behave.  Every gate script, every assertion in it, and the meaning of
   every exit code it returns are untouched, and `sh test/run_gates.sh` remains
   authoritative.  What `gate run` adds is the SERVICES around the script —
   scratch-dir lifecycle, the stale-oracle refusal, a timeout, separated
   stdout/stderr capture, and a machine-readable timing report — provided once,
   natively, instead of re-hand-rolled per gate.  See the `gate run` section
   below.

   **Selector language** (design doc §3, "keep it boring"): a selector is a
   `field:pattern` token, where `field` is one of `name`/`area`/`project`/
   `tier` and `pattern` is a glob (`*`, `?`).  A bare token with no `field:`
   prefix is sugar for `name:<token>`.  Several selectors on one command line
   are a CONJUNCTION — a gate must match all of them.

   ⚠️ A selector that matches ZERO gates is a HARD ERROR, never a green empty
   list.  That mirrors `test/run_gates.sh:181` ("no gates match: …", exit 1)
   deliberately: a mistyped pattern that silently selects nothing is how a
   shard certifies coverage of a gate that never ran. -}

import toml.{Toml, parse, getString, getArray, tableCount, tableEntry}
import json.{Json, JString, JInt, JFloat, JBool, jArray, jObject, stringify}
import driver.build_cmd.{envOr, defaultMedakaRoot}
import support.path.{joinPath}
import support.util.{
  endsWith,
  joinNl,
  joinWith,
  listLen,
  parseDecChecked,
  reverseL,
  sortUniqS,
  splitNl,
  stringTrim,
}

-- ── The entry schema ────────────────────────────────────────────────────────
-- One `[[gate]]` table in `test/gates.toml` per gate.  Every field below is
-- REQUIRED to be present in the file, list fields included: an absent list is
-- an error, not an empty list.  `sources`/`corpus` are populated in a later
-- slice, so today they are present-and-empty on every entry — which is a
-- different fact from "this gate has no sources", and the reader must not
-- blur the two by defaulting.

public export data Gate =
  | Gate {
      name : String,
      area : String,
      project : String,
      tier : String,
      cost : String,
      kind : String,
      run : String,
      oracles : List String,
      sources : List String,
      corpus : List String,
      toolchain : List String,
    }

-- ── Registry reading ────────────────────────────────────────────────────────

-- Pull one required string field out of a `[[gate]]` sub-document.
reqStr : Int -> String -> Toml -> Result String String
reqStr i field entry = match getString field entry
  Some s => Ok s
  None => Err "gates.toml: [[gate]] #\{intToString i}: missing required string field '\{field}'"

-- Pull one required string-array field.  Present-but-empty is fine; absent is
-- not (see the schema note above).
reqArr : Int -> String -> Toml -> Result String (List String)
reqArr i field entry = match getArray field entry
  Some xs => Ok xs
  None => Err "gates.toml: [[gate]] #\{intToString i}: missing required array field '\{field}'"

readGate : Toml -> Int -> Result String Gate
readGate doc i =
  let e = tableEntry "gate" i doc
  do
    name <- reqStr i "name" e
    area <- reqStr i "area" e
    project <- reqStr i "project" e
    tier <- reqStr i "tier" e
    cost <- reqStr i "cost" e
    kind <- reqStr i "kind" e
    run <- reqStr i "run" e
    oracles <- reqArr i "oracles" e
    sources <- reqArr i "sources" e
    corpus <- reqArr i "corpus" e
    toolchain <- reqArr i "toolchain" e
    Ok
      Gate {
        name = name,
        area = area,
        project = project,
        tier = tier,
        cost = cost,
        kind = kind,
        run = run,
        oracles = oracles,
        sources = sources,
        corpus = corpus,
        toolchain = toolchain,
      }

readGatesFrom : Toml -> Int -> Int -> List Gate -> Result String (List Gate)
readGatesFrom doc i n acc
  | i >= n = Ok (reverseGates acc [])
  | otherwise = match readGate doc i
    Err m => Err m
    Ok g => readGatesFrom doc (i + 1) n (g::acc)

reverseGates : List Gate -> List Gate -> List Gate
reverseGates [] acc = acc
reverseGates (g::gs) acc = reverseGates gs (g::acc)

{- | Parse a registry's TOML source into its gate entries, in file order.
   An empty registry is an error: an unreadable or empty `gates.toml` must not
   present as "the repo has no gates". -}
export
parseRegistry : String -> Result String (List Gate)
parseRegistry src = match parse src
  Err m => Err "gates.toml: \{m}"
  Ok doc =>
    let n = tableCount "gate" doc
    if n == 0 then
      Err "gates.toml: no [[gate]] entries found"
    else
      readGatesFrom doc 0 n []

-- ── Glob matching ───────────────────────────────────────────────────────────
-- `*` matches any run of characters (path separators included — the registry's
-- names are opaque strings, not paths), `?` matches exactly one.  Everything
-- else is literal.  This is the same shape `run_gates.sh` gets from the shell.

globMatchAt : Array Char -> Int -> Int -> Array Char -> Int -> Int -> Bool
globMatchAt pat pi pn s si sn
  | pi >= pn = si >= sn
  | arrayGetUnsafe pi pat == '*' = globStar pat pi pn s si sn
  | si >= sn = False
  | arrayGetUnsafe pi pat == '?' = globMatchAt pat (pi + 1) pn s (si + 1) sn
  | arrayGetUnsafe pi pat == arrayGetUnsafe si s =
    globMatchAt pat (pi + 1) pn s (si + 1) sn
  | otherwise = False

-- `*` at `pi`: try consuming 0, 1, 2, … characters of the subject.
globStar : Array Char -> Int -> Int -> Array Char -> Int -> Int -> Bool
globStar pat pi pn s si sn
  | globMatchAt pat (pi + 1) pn s si sn = True
  | si >= sn = False
  | otherwise = globStar pat pi pn s (si + 1) sn

{- | Glob match, `*`/`?` only.

   > globMatch "diff_compiler_*" "diff_compiler_parse_result"
   True

   > globMatch "diff_compiler_*" "build_cmd"
   False

   A pattern with no metacharacter is an exact match:

   > globMatch "backend" "backend"
   True

   > globMatch "backend" "backends"
   False

   `*` crosses `/` — registry names are opaque strings, not paths:

   > globMatch "sqlite/*" "sqlite/test/select_oracle"
   True -}
export
globMatch : String -> String -> Bool
globMatch pat s =
  let p = stringToChars pat
  let subj = stringToChars s
  globMatchAt p 0 (arrayLength p) subj 0 (arrayLength subj)

-- ── Selectors ───────────────────────────────────────────────────────────────

public export data Selector =
  | SelName String
  | SelArea String
  | SelProject String
  | SelTier String
deriving (Eq, Debug)

-- The `field:` prefixes, checked longest-first is unnecessary here (no prefix
-- is a prefix of another).
selPrefix : String -> String -> Option String
selPrefix pre tok =
  let pn = stringLength pre
  if stringLength tok >= pn && stringSlice 0 pn tok == pre then
    Some (stringSlice pn (stringLength tok) tok)
  else
    None

hasColon : String -> Bool
hasColon tok = colonAt (stringToChars tok) 0

colonAt : Array Char -> Int -> Bool
colonAt arr i
  | i >= arrayLength arr = False
  | arrayGetUnsafe i arr == ':' = True
  | otherwise = colonAt arr (i + 1)

{- | Parse one selector token.  An unrecognized `field:` prefix is an ERROR,
   not a fall-through to `name:` — `aria:backend` selecting every gate whose
   *name* is `aria:backend` (i.e. none) would report "matched no gates" and
   send the reader hunting for a missing gate instead of a typo'd field.

   > parseSelector "name:diff_compiler_*" == Ok (SelName "diff_compiler_*")
   True

   > parseSelector "area:backend" == Ok (SelArea "backend")
   True

   A bare token is `name:` sugar:

   > parseSelector "build_cmd" == Ok (SelName "build_cmd")
   True

   An unknown field is rejected:

   > parseSelector "aria:backend"
   Err "unknown selector field in 'aria:backend' (expected name:, area:, project: or tier:)" -}
export
parseSelector : String -> Result String Selector
parseSelector tok = match selPrefix "name:" tok
  Some v => Ok (SelName v)
  None => match selPrefix "area:" tok
    Some v => Ok (SelArea v)
    None => match selPrefix "project:" tok
      Some v => Ok (SelProject v)
      None => match selPrefix "tier:" tok
        Some v => Ok (SelTier v)
        None =>
          if hasColon tok then
            Err "unknown selector field in '\{tok}' (expected name:, area:, project: or tier:)"
          else
            Ok (SelName tok)

{- | Does a gate satisfy one selector?  Every field is glob-matched, so a
   literal value is an exact match and `area:back*` also works. -}
export
matchesSelector : Selector -> Gate -> Bool
matchesSelector (SelName p) g = globMatch p g.name
matchesSelector (SelArea p) g = globMatch p g.area
matchesSelector (SelProject p) g = globMatch p g.project
matchesSelector (SelTier p) g = globMatch p g.tier

-- Conjunction: a gate must satisfy EVERY selector given.
matchesAll : List Selector -> Gate -> Bool
matchesAll [] _ = True
matchesAll (s::ss) g = matchesSelector s g && matchesAll ss g

{- | Select the gates matching every selector, preserving registry order. -}
export
selectGates : List Selector -> List Gate -> List Gate
selectGates _ [] = []
selectGates sels (g::gs)
  | matchesAll sels g = g :: selectGates sels gs
  | otherwise = selectGates sels gs

-- ── Rendering ───────────────────────────────────────────────────────────────

renderNames : List Gate -> String
renderNames [] = ""
renderNames (g::gs) = "\{g.name}\n" ++ renderNames gs

gateJson : Gate -> Json
gateJson g = jObject
  [
    ("name", JString g.name),
    ("area", JString g.area),
    ("project", JString g.project),
    ("tier", JString g.tier),
    ("cost", JString g.cost),
    ("kind", JString g.kind),
    ("run", JString g.run),
    ("oracles", jArray (map JString g.oracles)),
    ("sources", jArray (map JString g.sources)),
    ("corpus", jArray (map JString g.corpus)),
    ("toolchain", jArray (map JString g.toolchain)),
  ]

{- | The `--json` rendering: a JSON array of entry objects, in registry order,
   every schema field present. -}
export
renderJson : List Gate -> String
renderJson gs = stringify (jArray (map gateJson gs))

-- ── CLI ─────────────────────────────────────────────────────────────────────

export
gateHelpText : String
gateHelpText = stringConcat
  [
    "medaka gate — Query the gate registry (test/gates.toml)\n",
    "\n",
    "Usage:\n",
    "  medaka gate list [<selector>...] [--json] [--registry <path>]\n",
    "  medaka gate run  [<selector>...] [--dry-run] [--json] [--report <path>]\n",
    "                   [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n",
    "                   [--registry <path>]\n",
    "\n",
    "Selectors (conjunction — a gate must match all of them):\n",
    "  name:<glob>      gate name, e.g. name:diff_compiler_*\n",
    "  area:<glob>      semantic area, e.g. area:backend\n",
    "  project:<glob>   owning project, e.g. project:sqlite\n",
    "  tier:<glob>      merge | nightly | ondemand\n",
    "  <glob>           sugar for name:<glob>\n",
    "\n",
    "A selector matching zero gates is an error, not an empty list.\n",
    "\n",
    "  --json             list: the registry entries as JSON.\n",
    "                     run: the machine-readable run report as JSON.\n",
    "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n",
    "\n",
    "`gate run` only:\n",
    "  --dry-run          print the resolved invocation plan; execute nothing\n",
    "  --report <path>    write the per-gate timing report (JSON) to <path>\n",
    "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n",
    "                     cheap 300s, medium 900s, heavy 3600s)\n",
    "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n",
    "                     value is recorded in the report.  Medaka has no\n",
    "                     concurrency primitive (stdlib/runtime.mdk has no\n",
    "                     fork/waitpid) and runCommand blocks.\n",
    "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n",
    "                     it is also skipped whenever CI is set, on purpose)\n",
    "\n",
    "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n",
    "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n",
    "\n",
    "`gate verify` and `gate explain` are not implemented yet\n",
    "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n",
  ]

-- Parsed `gate list` argv.
data ListArgs =
  | ListArgs { json : Bool, registry : Option String, selectors : List String }

parseListArgs : List String -> ListArgs -> Result String ListArgs
parseListArgs [] acc =
  Ok ListArgs { acc | selectors = reverseStrs acc.selectors [] }
parseListArgs ("--json"::rest) acc =
  parseListArgs rest ListArgs { acc | json = True }
parseListArgs ("--registry"::p::rest) acc =
  parseListArgs rest ListArgs { acc | registry = Some p }
parseListArgs ("--registry"::[]) _ =
  Err "medaka gate list: --registry needs a path"
parseListArgs (a::rest) acc
  | stringLength a > 0 && stringSlice 0 1 a == "-" =
    Err "medaka gate list: unknown flag: \{a}"
  | otherwise =
    parseListArgs rest ListArgs { acc | selectors = a::acc.selectors }

reverseStrs : List String -> List String -> List String
reverseStrs [] acc = acc
reverseStrs (x::xs) acc = reverseStrs xs (x::acc)

parseSelectors : List String -> List Selector -> Result String (List Selector)
parseSelectors [] acc = Ok (reverseSels acc [])
parseSelectors (t::ts) acc = match parseSelector t
  Err m => Err m
  Ok s => parseSelectors ts (s::acc)

reverseSels : List Selector -> List Selector -> List Selector
reverseSels [] acc = acc
reverseSels (s::ss) acc = reverseSels ss (s::acc)

-- `<MEDAKA_ROOT>/test/gates.toml` unless --registry overrides it.  MEDAKA_ROOT
-- resolves exe-relative like every other asset (build_cmd.defaultMedakaRoot),
-- so a relocated binary finds its own tree, not the cwd.
registryPath : Option String -> <IO> String
registryPath (Some p) = p
registryPath None =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  joinPath (joinPath root "test") "gates.toml"

-- Every way `list` can end, as one value: the text to print, or the message to
-- die with.  Keeping this a `Result` rather than sprinkling `exit 1` gives the
-- command a SINGLE exit site (`emit`), so no error path can grow a
-- print-without-exit or an exit-without-print.
listOutput : List String -> <IO> Result String String
listOutput argv = match parseListArgs argv ListArgs { json = False, registry = None, selectors = [] }
  Err m => Err m
  Ok a => match parseSelectors a.selectors []
    Err m => Err "medaka gate list: \{m}"
    Ok sels =>
      let path = registryPath a.registry
      match readFile path
        Err m => Err "medaka gate list: cannot read registry: \{m}"
        Ok src => match parseRegistry src
          Err m => Err "medaka gate list: \{m}"
          Ok gates =>
            selectionOutput a.json a.selectors (selectGates sels gates) path

-- A selector that selects nothing is a HARD ERROR (see the module header).
selectionOutput : Bool -> List String -> List Gate -> String -> Result String String
selectionOutput _ tokens [] path
  | isEmptyStrs tokens = Err "medaka gate list: \{path} contains no gates"
  | otherwise = Err "medaka gate list: no gates match: \{joinSpace tokens}"
selectionOutput isJson _ (g::gs) _ =
  if isJson then
    Ok (renderJson (g::gs) ++ "\n")
  else
    Ok (renderNames (g::gs))

-- The command's only exit site.
emit : Result String String -> <IO> Unit
emit (Err msg) =
  let _ = ePutStrLn msg
  exit 1
emit (Ok out) = putStr out

isEmptyStrs : List String -> Bool
isEmptyStrs [] = True
isEmptyStrs _ = False

joinSpace : List String -> String
joinSpace [] = ""
joinSpace (x::[]) = x
joinSpace (x::xs) = "\{x} \{joinSpace xs}"

{- | `medaka gate <sub> …`.  Only `list` exists in this slice; `run`/`verify`/
   `explain` are named explicitly so an agent reaching for one gets told they
   are not here yet rather than a generic "unknown subcommand". -}
export
runGateCmd : List String -> <IO> Unit
runGateCmd [] =
  emit (Err "usage: medaka gate <list|run> [<selector>...] [--json]")
runGateCmd ("list"::rest) = emit (listOutput rest)
runGateCmd ("run"::rest) = runRunCmdBody rest
runGateCmd ("verify"::_) =
  emit (Err
    "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")
runGateCmd ("explain"::_) =
  emit (Err
    "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")
runGateCmd (sub::_) =
  emit (Err "medaka gate: unknown subcommand '\{sub}' (expected: list, run)")

-- ── `gate run` ──────────────────────────────────────────────────────────────
--
-- `medaka gate run <selector>...` executes the selected gates and provides,
-- once and natively, the services every individual gate script (and
-- `test/run_gates.sh` around them) reimplements ad hoc:
--
--   * a PER-GATE SCRATCH DIR, handed to the gate as `TMPDIR` so its own
--     `mktemp -d` lands inside it, and removed after the gate returns — on
--     failure and on timeout alike.  Routed through
--     `${MEDAKA_SCRATCH:-/var/tmp/medaka-scratch}`, never bare `/tmp`, because
--     `/tmp` is a RAM-BACKED tmpfs here and leaked scratch there is a MEMORY
--     leak with no guilty process (test/lib_scratch.sh).
--   * the [G-STALE-ORACLE] REFUSAL, including its deliberate disabled-in-CI arm.
--   * a TIMEOUT per gate — a fuse against a hang, which no gate has today.
--   * STDERR-PRESERVING capture: stdout and stderr are captured separately and
--     both surfaced on failure, so a stderr-only staleness warning ([B-STDERR])
--     can never be silently dropped.
--   * the `N ok, M failing` summary, and a machine-readable per-gate timing
--     report (`--json` / `--report <path>`) — #2180's future input.  This slice
--     ENFORCES NOTHING with those timings.
--
-- BEHAVIOR-NEUTRAL FOR EVERY EXISTING GATE.  This is a new alternate way to
-- INVOKE a gate script; the script, its assertions, and the meaning of its exit
-- code are untouched, and `sh test/run_gates.sh` remains authoritative.
--
-- ⚠️ NO OK/FAILING NORMALIZATION.  The raw exit code is reported as-is.
-- `diff_compiler_must_fail` has INVERTED polarity ([G-MUST-FAIL]) — RED is its
-- healthy state — and the registry carries no per-entry ok/failing semantic, so
-- nothing here may assume exit 0 means "good".  Interpreting polarity stays with
-- the human (or the shard) above this command, exactly as with `run_gates.sh`.

-- One gate's outcome.  `spawnError` is "" unless the process could not be
-- started at all (a missing script, a failed `mktemp`, an ENOENT on `env`) —
-- which is a DIFFERENT fact from "the gate ran and exited non-zero", and the
-- two must not be blurred into one failure count without saying which.
public export data GateResult =
  | GateResult {
      name : String,
      script : String,
      shell : String,
      exitCode : Int,
      timedOut : Bool,
      spawnError : String,
      seconds : Float,
      out : String,
      err : String,
    }

-- Everything a gate invocation needs that is the same for every gate in a run.
data RunEnv =
  | RunEnv {
      root : String,
      medaka : String,
      emitter : String,
      scratchRoot : String,
      timeoutOverride : Int,
    }

-- ── timeout policy ──────────────────────────────────────────────────────────
--
-- A FUSE, NOT A BUDGET.  The bound exists so a hung gate cannot hold this
-- command (or a CI runner) forever; it is deliberately far above any gate's
-- real runtime, because a bound tight enough to be a perf budget would make
-- `medaka gate run` behavior-CHANGING for the slowest gates — and per-gate cost
-- budgets are #2180's job, fed by the timing report this command emits, not
-- something to smuggle in as a kill signal.  `diff_compiler_perf_scaling` and
-- `diff_compiler_engines` can already exceed the 10-minute foreground ceiling
-- ([L-FOREGROUND-CEILING]), which is why `heavy` is an hour and not ten minutes.
--
-- The registry's `cost` today takes exactly three values (cheap/medium/heavy);
-- an unrecognized one gets the middle bound rather than an error, so a future
-- tier added to the schema degrades to "still fused" instead of "won't run".
timeoutFor : Int -> String -> Int
timeoutFor override cost
  | override > 0 = override
  | cost == "cheap" = 300
  | cost == "medium" = 900
  | cost == "heavy" = 3600
  | otherwise = 900

-- ── scratch ─────────────────────────────────────────────────────────────────

-- The scratch ROOT, mirroring test/lib_scratch.sh's rule exactly: an explicit
-- TMPDIR wins unless it is the RAM-backed `/tmp`, in which case MEDAKA_SCRATCH
-- (default /var/tmp/medaka-scratch) takes over.
scratchRootOf : Unit -> <IO> String
scratchRootOf _ =
  let t = envOr "TMPDIR" ""
  if t /= "" && stripSlash t /= "/tmp" then
    t
  else
    envOr "MEDAKA_SCRATCH" "/var/tmp/medaka-scratch"

stripSlash : String -> String
stripSlash s =
  let n = stringLength s
  if n > 1 && stringSlice (n - 1) n s == "/" then stringSlice 0 (n - 1) s else s

-- `mktemp -d` under the scratch root.  The 6-X template is accepted by both GNU
-- and BSD mktemp; `mkdir -p` first because the root may not exist yet.
makeGateScratch : String -> <IO> Result String String
makeGateScratch root = match runCommand "mkdir" ["-p", root]
  Err e => Err e
  Ok _ => match runCommand "mktemp" ["-d", "\{root}/medaka_gate_XXXXXX"]
    Err e => Err e
    Ok (0, out, _) =>
      let d = stringTrim out
      if d == "" then Err "mktemp -d printed no path" else Ok d
    Ok (_, _, mtErr) =>
      let msg = stringTrim mtErr
      Err (if msg == "" then "mktemp -d failed" else msg)

-- Best-effort recursive removal.  A gate writes an arbitrary TREE under its
-- scratch dir (fixtures, oracle output, its own nested mktemp dirs), so the
-- flat removeFile walk `medaka build` uses is not enough here.
cleanupScratch : String -> <IO> Unit
cleanupScratch dir =
  let _ = runCommand "rm" ["-rf", dir]
  ()

-- ── [G-STALE-ORACLE] ────────────────────────────────────────────────────────
--
-- A stale oracle does not fail — it LIES, and its ordinary-looking FAIL is
-- indistinguishable from a real regression (test/run_gates.sh:183-298 tells the
-- three incidents).  So: refuse, name the probes, print the NARROW per-probe
-- rebuild command.
--
-- ⚠️ DISABLED WHEN `CI` IS SET, ON PURPOSE — this reproduces run_gates.sh:215
-- (`[ -z "${CI:-}" ]`) rather than dropping it.  CI restores test/bin from a
-- cache keyed on a CONTENT HASH of compiler/stdlib/runtime, which is strictly
-- stronger than an mtime comparison, while `actions/checkout` stamps fresh
-- mtimes on the sources — so mtime says "stale" about oracles proven current
-- and would red-light every shard.  Keep the weak local heuristic for local
-- trees; defer to the strong signal where it exists.
--
-- Unlike run_gates.sh this does NOT scrape `test/bin/<name>` out of the gate
-- script: the registry's `oracles` field already carries that list (S-2), and
-- the registry is the point.

hasSourceExt : String -> Bool
hasSourceExt p = endsWith ".mdk" p || endsWith ".c" p || endsWith ".h" p

newestMtimeIn : String -> Float -> <IO> Float
newestMtimeIn path acc = match statFile path
  Err _ => acc
  Ok (_, isDir, _, mt) => if isDir then match listDir path
    Err _ => acc
    Ok names => newestMtimeEntries path names acc
  else if hasSourceExt path && mt > acc then mt else acc

newestMtimeEntries : String -> List String -> Float -> <IO> Float
newestMtimeEntries _ [] acc = acc
newestMtimeEntries dir (n::rest) acc =
  newestMtimeEntries dir rest (newestMtimeIn "\{dir}/\{n}" acc)

-- The same source set run_gates.sh scans: compiler/ and stdlib/ *.mdk, plus
-- runtime/ *.c and *.h.
newestSourceMtime : String -> <IO> Float
newestSourceMtime root =
  let a = newestMtimeIn "\{root}/compiler" 0.0
  let b = newestMtimeIn "\{root}/stdlib" a
  newestMtimeIn "\{root}/runtime" b

-- Every oracle the SELECTED gates read, deduped — never all of test/bin.  The
-- wasm probes are built by a different script and are routinely older than
-- source; complaining about one a run never opens is how this check gets
-- switched off wholesale.
selectedOracles : List Gate -> List String
selectedOracles [] = []
selectedOracles (g::gs) = g.oracles ++ selectedOracles gs

-- MISSING is not stale — the gate's own "oracle not built" exit-2 owns that
-- case and says so in its own words.
staleOf : String -> Float -> List String -> <IO> List String
staleOf _ _ [] = []
staleOf root newest (o::os) =
  let rest = staleOf root newest os
  match statFile "\{root}/test/bin/\{o}"
    Err _ => rest
    Ok (_, _, _, mt) => if mt < newest then o::rest else rest

indentedNames : List String -> List String
indentedNames [] = []
indentedNames (o::os) = "  \{o}" :: indentedNames os

staleBannerLines : List String -> List String
staleBannerLines [] = []
staleBannerLines (o::os) =
  "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one \{o}" ::
    staleBannerLines os

staleBanner : List String -> String
staleBanner stale =
  joinNl
    ([
      "════════════════════════════════════════════════════════════════════",
      "STALE ORACLES (\{intToString (listLen stale)}) — REFUSING TO RUN.",
      "",
      joinNl (indentedNames stale),
      "",
      "These probe binaries are OLDER than compiler/ stdlib/ runtime/ source.",
      "A gate reading one is testing a compiler that no longer exists — and it",
      "reports an ordinary-looking FAIL that is INDISTINGUISHABLE from a real",
      "regression.",
      "",
      "Rebuild ONLY what is stale — one probe per command:",
    ] ++ staleBannerLines stale ++ [
      "",
      "(Override with NO_STALE_CHECK=1, --no-stale-check, or CI=1 only if you",
      " know exactly why.  This check is skipped in CI on purpose — see the",
      " comment above staleOf.)",
      "════════════════════════════════════════════════════════════════════",
      "",
    ])

-- run_gates.sh's `[ -z "${VAR:-}" ]`: SET-BUT-EMPTY counts as unset.
envSet : String -> <IO> Bool
envSet name = envOr name "" /= ""

staleRefusal : Bool -> String -> List Gate -> <IO> Option String
staleRefusal True _ _ = None
staleRefusal False root gs =
  if envSet "CI" || envSet "NO_STALE_CHECK" then None
  else
    let names = sortUniqS (selectedOracles gs)
    let newest = newestSourceMtime root
    match staleOf root newest names
      [] => None
      stale => Some (staleBanner stale)

-- ── running one gate ────────────────────────────────────────────────────────

-- HONOR THE SHEBANG, do not hardcode `sh`.  Six gates under test/ and all 22
-- sqlite oracles are `#!/usr/bin/env bash` and use bashisms; under dash all 22
-- sqlite gates FAIL while passing perfectly when invoked directly, and "the
-- gate ran under an interpreter it wasn't written for" is the purest form of a
-- harness bug wearing a compiler bug's clothes (test/run_gates.sh:105-115).
shellFor : String -> <IO> String
shellFor script = match readFile script
  Err _ => "sh"
  Ok src => if substrIn "bash" (firstLineOf src) then "bash" else "sh"

firstLineOf : String -> String
firstLineOf s = match splitNl s
  [] => ""
  l::_ => l

substrIn : String -> String -> Bool
substrIn needle hay =
  substrAt needle hay 0 (stringLength hay - stringLength needle)

substrAt : String -> String -> Int -> Int -> Bool
substrAt needle hay i last
  | i > last = False
  | stringSlice i (i + stringLength needle) hay == needle = True
  | otherwise = substrAt needle hay (i + 1) last

-- The invocation.  `runCommand` takes no environment and Medaka has no setEnv,
-- so the environment goes through POSIX `env` — the same device
-- build_cmd.withEmitHalf uses.  The variables mirror run_gates.sh's exports
-- (defaults only: an explicit value in this process's environment already won,
-- via envOr, before it got here).  `JOBS=1` because this runner is sequential
-- (see the note on --jobs).
--
-- `timeout -k 5s <N>s` is GNU coreutils' (present on this box and on every CI
-- runner — CI is 100% ubuntu-latest, [B-CI-UBUNTU-ONLY]).  It exits 124 on the
-- SIGTERM path and 137 when the -k grace period had to escalate to SIGKILL;
-- both are reported as a timeout, with the raw code still printed so a genuine
-- 137 from elsewhere (an OOM kill, say) is not hidden by the label.
gateArgs : RunEnv -> String -> Int -> String -> String -> List String
gateArgs env scratch secs sh script = [
  "MEDAKA_ROOT=\{env.root}",
  "MEDAKA=\{env.medaka}",
  "MEDAKA_EMITTER=\{env.emitter}",
  "TMPDIR=\{scratch}",
  "MEDAKA_SCRATCH=\{scratch}",
  "JOBS=1",
  "timeout",
  "-k",
  "5s",
  "\{intToString secs}s",
  sh,
  script,
]

spawnFailure : Gate -> String -> String -> Float -> GateResult
spawnFailure g script msg dt = GateResult {
  name = g.name,
  script = script,
  shell = "sh",
  exitCode = 127,
  timedOut = False,
  spawnError = msg,
  seconds = dt,
  out = "",
  err = "",
}

runOneGate : RunEnv -> Gate -> <IO> GateResult
runOneGate env g =
  let script = "\{env.root}/\{g.run}"
  if not (fileExists script) then spawnFailure g script "gate script not found (registry `run` field): \{g.run}" 0.0
  else
    let sh = shellFor script
    let secs = timeoutFor env.timeoutOverride g.cost
    match makeGateScratch env.scratchRoot
      Err e => spawnFailure g script "could not create a scratch dir: \{e}" 0.0
      Ok scratch =>
        let t0 = monotonicSec ()
        let res = runCommand "env" (gateArgs env scratch secs sh script)
        let dt = monotonicSec () - t0
        let _ = cleanupScratch scratch
        match res
          Err e => spawnFailure g script "could not spawn the gate: \{e}" dt
          Ok (code, out, errOut) => GateResult {
            name = g.name,
            script = script,
            shell = sh,
            exitCode = code,
            timedOut = code == 124 || code == 137,
            spawnError = "",
            seconds = dt,
            out = out,
            err = errOut,
          }

gateOk : GateResult -> Bool
gateOk r = r.spawnError == "" && r.exitCode == 0

msOf : GateResult -> Int
msOf r = floatToInt (r.seconds * 1000.0)

resultLine : GateResult -> String
resultLine r
  | r.spawnError /= "" = "ERROR \{r.name}  (\{r.spawnError})\n"
  | r.timedOut = "TIMEOUT \{r.name}  (exit \{intToString r.exitCode} after \{intToString (msOf r)}ms)\n"
  | r.exitCode == 0 = "PASS  \{r.name}  (\{intToString (msOf r)}ms)\n"
  | otherwise = "FAIL  \{r.name}  (exit \{intToString r.exitCode}, \{intToString (msOf r)}ms)\n"

-- ── the sequential loop ─────────────────────────────────────────────────────
--
-- ⚠️ SEQUENTIAL, and `--jobs` IS ACCEPTED BUT IGNORED.  Medaka has no
-- concurrency primitive to build a job pool out of: `runCommand` is a single
-- BLOCKING call and stdlib/runtime.mdk has no fork/waitpid/spawn extern (derive:
-- `grep -n 'fork\|waitPid\|spawn' stdlib/runtime.mdk` — nothing).
-- `run_gates.sh` gets its pool from `xargs -P`, which needs either a new extern
-- or a generated shell script that would have to re-own the scratch, timeout and
-- capture services this command exists to provide natively.  Rather than fake
-- it, `--jobs` is parsed, honoured in the report as the requested value, and
-- reported in the summary as `sequential` — see the report's Notes.
runGatesLoop : RunEnv -> List Gate -> List GateResult -> <IO> List GateResult
runGatesLoop _ [] acc = reverseL acc
runGatesLoop env (g::gs) acc =
  let r = runOneGate env g
  let _ = putStr (resultLine r)
  let _ = flushStdout ()
  runGatesLoop env gs (r::acc)

-- ── failure output ──────────────────────────────────────────────────────────
--
-- Print the failing gate's output.  run_gates.sh discarded it for a long time,
-- which made a red CI shard undiagnosable (its mktemp dir dies with the runner);
-- the fix there was to tail the log, and the bound is 200 lines because
-- `diff_compiler_must_fail` alone prints 77 on a single drained row.
--
-- STDOUT AND STDERR ARE PRINTED SEPARATELY AND BOTH ARE PRINTED ([B-STDERR]):
-- the stale-binary warning is stderr-only, and a gate that fails BECAUSE its
-- binary is stale says so nowhere else.

-- The offset just PAST the `want`-th newline — i.e. where the last
-- `total - want` lines begin.  Sliced out of the original string rather than
-- dropped off the head of `splitNl`'s list and rejoined, because a generic
-- list drop here would be a byte-identical twin of `typecheck.dropN` (which is
-- private, so it cannot be shared) and `rule-duplicate-body` is a CROSS-FILE
-- rule — it would fire on typecheck.mdk too, and silencing it there would move
-- a LEG A golden for a 200-line output bound.
afterNewlines : Array Char -> Int -> Int -> Int -> Int
afterNewlines cs i len want
  | i >= len = len
  | want <= 0 = i
  | arrayGetUnsafe i cs == '\n' = afterNewlines cs (i + 1) len (want - 1)
  | otherwise = afterNewlines cs (i + 1) len want

tailLines : Int -> String -> String
tailLines n s =
  let k = listLen (splitNl s)
  if k <= n then s
  else
    let cs = stringToChars s
    stringSlice (afterNewlines cs 0 (arrayLength cs) (k - n)) (stringLength s) s

failureDetail : GateResult -> String
failureDetail r =
  let hdr = "\n───── \{r.name} — \{r.shell} \{r.script} (exit \{intToString r.exitCode}) ─────\n"
  let o = if stringTrim r.out == "" then
    "  (stdout: empty)\n"
  else
    "  ── stdout ──\n\{tailLines 200 r.out}\n"
  let e = if stringTrim r.err == "" then
    "  (stderr: empty)\n"
  else
    "  ── stderr ──\n\{tailLines 200 r.err}\n"
  "\{hdr}\{o}\{e}"

failureDetails : List GateResult -> String
failureDetails [] = ""
failureDetails (r::rs)
  | gateOk r = failureDetails rs
  | otherwise = failureDetail r ++ failureDetails rs

-- ── summary + report ────────────────────────────────────────────────────────

countOk : List GateResult -> Int
countOk [] = 0
countOk (r::rs) = (if gateOk r then 1 else 0) + countOk rs

failingNames : List GateResult -> List String
failingNames [] = []
failingNames (r::rs)
  | gateOk r = failingNames rs
  | otherwise = r.name :: failingNames rs

resultJson : GateResult -> Json
resultJson r = jObject
  [
    ("name", JString r.name),
    ("script", JString r.script),
    ("shell", JString r.shell),
    ("exit", JInt r.exitCode),
    ("timedOut", JBool r.timedOut),
    ("ms", JInt (msOf r)),
    ("seconds", JFloat r.seconds),
    ("ok", JBool (gateOk r)),
    ("spawnError", JString r.spawnError),
    ("stdout", JString r.out),
    ("stderr", JString r.err),
  ]

{- | The machine-readable run report: per-gate timings plus the ok/failing
   tallies.  #2180 (the CI cost ratchet) is the intended consumer; NOTHING in
   this slice enforces a budget from it. -}
export
runReportJson : Int -> List GateResult -> String
runReportJson jobs rs = stringify (jObject
  [
    ("jobs", JInt jobs),
    ("parallel", JBool False),
    ("ok", JInt (countOk rs)),
    ("failing", JInt (listLen rs - countOk rs)),
    ("gates", jArray (map resultJson rs)),
  ])

-- ── the dry run ─────────────────────────────────────────────────────────────
--
-- The resolved INVOCATION PLAN, executing nothing.  One line per gate, in
-- registry order, carrying exactly what `run` would do: the interpreter, the
-- absolute script path, the fuse, and the oracles the stale check will consult.
-- The script path is the field a parity diff against `run_gates.sh`'s own
-- resolved gate list compares.
dryLine : RunEnv -> Gate -> <IO> String
dryLine env g =
  let script = "\{env.root}/\{g.run}"
  let sh = if fileExists script then shellFor script else "sh"
  let orc = if isEmptyStrs g.oracles then "-" else joinWith "," g.oracles
  "\{g.name}\t\{sh}\t\{script}\ttimeout=\{intToString (timeoutFor env.timeoutOverride g.cost)}s\toracles=\{orc}\n"

dryLines : RunEnv -> List Gate -> <IO> String
dryLines _ [] = ""
dryLines env (g::gs) = dryLine env g ++ dryLines env gs

-- ── the `run` subcommand ────────────────────────────────────────────────────

data RunArgs =
  | RunArgs {
      registry : Option String,
      selectors : List String,
      dryRun : Bool,
      json : Bool,
      report : Option String,
      timeoutSecs : Int,
      jobs : Int,
      noStaleCheck : Bool,
    }

parseRunArgs : List String -> RunArgs -> Result String RunArgs
parseRunArgs [] acc =
  Ok RunArgs { acc | selectors = reverseStrs acc.selectors [] }
parseRunArgs ("--dry-run"::rest) acc =
  parseRunArgs rest RunArgs { acc | dryRun = True }
parseRunArgs ("--json"::rest) acc =
  parseRunArgs rest RunArgs { acc | json = True }
parseRunArgs ("--no-stale-check"::rest) acc =
  parseRunArgs rest RunArgs { acc | noStaleCheck = True }
parseRunArgs ("--registry"::p::rest) acc =
  parseRunArgs rest RunArgs { acc | registry = Some p }
parseRunArgs ("--registry"::[]) _ =
  Err "medaka gate run: --registry needs a path"
parseRunArgs ("--report"::p::rest) acc =
  parseRunArgs rest RunArgs { acc | report = Some p }
parseRunArgs ("--report"::[]) _ = Err "medaka gate run: --report needs a path"
parseRunArgs ("--timeout"::v::rest) acc = match parseDecChecked v
  None => Err "medaka gate run: --timeout needs a whole number of seconds, got '\{v}'"
  Some n => parseRunArgs rest RunArgs { acc | timeoutSecs = n }
parseRunArgs ("--timeout"::[]) _ =
  Err "medaka gate run: --timeout needs a number of seconds"
parseRunArgs ("--jobs"::v::rest) acc = match parseDecChecked v
  None => Err "medaka gate run: --jobs needs a whole number, got '\{v}'"
  Some n => parseRunArgs rest RunArgs { acc | jobs = n }
parseRunArgs ("--jobs"::[]) _ = Err "medaka gate run: --jobs needs a number"
parseRunArgs (a::rest) acc
  | stringLength a > 0 && stringSlice 0 1 a == "-" =
    Err "medaka gate run: unknown flag: \{a}"
  | otherwise = parseRunArgs rest RunArgs { acc | selectors = a::acc.selectors }

emptyRunArgs : RunArgs
emptyRunArgs = RunArgs {
  registry = None,
  selectors = [],
  dryRun = False,
  json = False,
  report = None,
  timeoutSecs = 0,
  jobs = 1,
  noStaleCheck = False,
}

-- The selection half, shared with `list`: read the registry, apply the
-- selectors, and treat a zero-gate selection as a HARD ERROR.  A mistyped
-- pattern that silently selects nothing is how a shard certifies coverage of a
-- gate that never ran (test/run_gates.sh:181).
selectFor : String -> List String -> List Selector -> String -> Result String (List Gate)
selectFor path tokens sels src = match parseRegistry src
  Err m => Err "medaka gate run: \{m}"
  Ok gates => match selectGates sels gates
    [] =>
      if isEmptyStrs tokens then
        Err "medaka gate run: \{path} contains no gates"
      else
        Err "medaka gate run: no gates match: \{joinSpace tokens}"
    sel => Ok sel

runEnvFor : RunArgs -> <IO> RunEnv
runEnvFor a =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  RunEnv {
    root = root,
    medaka = envOr "MEDAKA" "\{root}/medaka",
    emitter = envOr "MEDAKA_EMITTER" "\{root}/medaka_emitter",
    scratchRoot = scratchRootOf (),
    timeoutOverride = a.timeoutSecs,
  }

-- Write the timing report, if one was asked for.  A failed write is LOUD: a
-- silently-absent report is exactly the shape of hole this registry exists to
-- close.
writeReport : Option String -> String -> <IO> Bool
writeReport None _ = True
writeReport (Some p) body = match writeFile p body
  Err m =>
    let _ = ePutStrLn "medaka gate run: could not write --report \{p}: \{m}"
    False
  Ok _ => True

summaryLine : Int -> List GateResult -> String
summaryLine jobs rs =
  let ok = countOk rs
  let bad = listLen rs - ok
  "\n=== gate run: \{intToString ok} ok, \{intToString bad} failing (\{intToString (listLen rs)} gates, --jobs \{intToString jobs} requested, run SEQUENTIALLY) ===\n"

-- Everything after the gates have run: details, summary, report, exit code.
finishRun : RunArgs -> List GateResult -> <IO> Unit
finishRun a rs =
  let wrote = writeReport a.report (runReportJson a.jobs rs ++ "\n")
  let _ = if a.json then putStr (runReportJson a.jobs rs ++ "\n") else ()
  let _ = if a.json then () else putStr (failureDetails rs)
  let _ = if a.json then () else putStr (summaryLine a.jobs rs)
  let bad = failingNames rs
  let _ = if a.json || isEmptyStrs bad then
    ()
  else
    putStr "FAILING: \{joinSpace bad}\n"
  if isEmptyStrs bad && wrote then exit 0 else exit 1

runSelected : RunArgs -> List Gate -> <IO> Unit
runSelected a gs =
  let env = runEnvFor a
  if a.dryRun then putStr (dryLines env gs)
  else match staleRefusal a.noStaleCheck env.root gs
    Some banner =>
      let _ = ePutStr banner
      exit 1
    None => finishRun a (runGatesLoop env gs [])

runRunCmdBody : List String -> <IO> Unit
runRunCmdBody argv = match parseRunArgs argv emptyRunArgs
  Err m => emit (Err m)
  Ok a => match parseSelectors a.selectors []
    Err m => emit (Err "medaka gate run: \{m}")
    Ok sels =>
      let path = registryPath a.registry
      match readFile path
        Err m => emit (Err "medaka gate run: cannot read registry: \{m}")
        Ok src => match selectFor path a.selectors sels src
          Err m => emit (Err m)
          Ok gs => runSelected a gs
-- ── Properties ──────────────────────────────────────────────────────────────

prop "a bare selector token is name: sugar" (n : Int) =
  parseSelector (intToString n) == Ok (SelName (intToString n))

prop "an explicit name: selector agrees with the bare form" (n : Int) =
  parseSelector ("name:" ++ intToString n) == parseSelector (intToString n)

prop "a literal glob matches itself and nothing longer" (n : Int) = globMatch (intToString n) (intToString n)
  && not (globMatch (intToString n) (intToString n ++ "x"))

prop "a trailing * matches any suffix" (n : Int) =
  globMatch "g*" ("g" ++ intToString n)
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "endsWith" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DTypeSig false "globMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globMatchAt" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EBinOp ">=" (EVar "pi") (EVar "pn")) (EBinOp ">=" (EVar "si") (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "?"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "globStar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globStar" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EVar "True") (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "stringToChars") (EVar "pat"))) (DoLet false false (PVar "subj") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "p")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "p"))) (EVar "subj")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "subj"))))))
(DData Public "Selector" () ((variant "SelName" (ConPos (TyCon "String"))) (variant "SelArea" (ConPos (TyCon "String"))) (variant "SelProject" (ConPos (TyCon "String"))) (variant "SelTier" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Selector")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SelName" (PVar "__a0")) (PCon "SelName" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelArea" (PVar "__a0")) (PCon "SelArea" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelProject" (PVar "__a0")) (PCon "SelProject" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelTier" (PVar "__a0")) (PCon "SelTier" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Selector")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SelName" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelName ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelArea" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelArea ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelProject" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelProject ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelTier" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelTier ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig false "selPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "selPrefix" ((PVar "pre") (PVar "tok")) (EBlock (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "tok")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "tok")) (EVar "pre"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))) (EVar "None")))))
(DTypeSig false "hasColon" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasColon" ((PVar "tok")) (EApp (EApp (EVar "colonAt") (EApp (EVar "stringToChars") (EVar "tok"))) (ELit (LInt 0))))
(DTypeSig false "colonAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "colonAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ":"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "colonAt") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "parseSelector" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Selector"))))
(DFunDef false "parseSelector" ((PVar "tok")) (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "name:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "area:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelArea") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "project:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelProject") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "tier:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelTier") (EVar "v")))) (arm (PCon "None") () (EIf (EApp (EVar "hasColon") (EVar "tok")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown selector field in '")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' (expected name:, area:, project: or tier:)")))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "tok")))))))))))))
(DTypeSig true "matchesSelector" (TyFun (TyCon "Selector") (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesSelector" ((PCon "SelName" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "name")))
(DFunDef false "matchesSelector" ((PCon "SelArea" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "area")))
(DFunDef false "matchesSelector" ((PCon "SelProject" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "project")))
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "tier")))
(DTypeSig false "matchesAll" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesAll" ((PList) PWild) (EVar "True"))
(DFunDef false "matchesAll" ((PCons (PVar "s") (PVar "ss")) (PVar "g")) (EBinOp "&&" (EApp (EApp (EVar "matchesSelector") (EVar "s")) (EVar "g")) (EApp (EApp (EVar "matchesAll") (EVar "ss")) (EVar "g"))))
(DTypeSig true "selectGates" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "selectGates" (PWild (PList)) (EListLit))
(DFunDef false "selectGates" ((PVar "sels") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "matchesAll") (EVar "sels")) (EVar "g")) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run  [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                   [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                   [--registry <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` and `gate explain` are not implemented yet\n")) (ELit (LString "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate list: --registry needs a path"))))
(DFunDef false "parseListArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: unknown flag: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "parseSelectors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Selector"))))))
(DFunDef false "parseSelectors" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseSels") (EVar "acc")) (EListLit))))
(DFunDef false "parseSelectors" ((PCons (PVar "t") (PVar "ts")) (PVar "acc")) (EMatch (EApp (EVar "parseSelector") (EVar "t")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "parseSelectors") (EVar "ts")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "reverseSels" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyCon "List") (TyCon "Selector")))))
(DFunDef false "reverseSels" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseSels" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseSels") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "registryPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "registryPath" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "registryPath" ((PCon "None")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gates.toml"))))))
(DTypeSig false "listOutput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path")))))))))))))
(DTypeSig false "selectionOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "selectionOutput" (PWild (PVar "tokens") (PList) (PVar "path")) (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: no gates match: ")) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "selectionOutput" ((PVar "isJson") PWild (PCons (PVar "g") (PVar "gs")) PWild) (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderJson") (EBinOp "::" (EVar "g") (EVar "gs"))) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderNames") (EBinOp "::" (EVar "g") (EVar "gs"))))))
(DTypeSig false "emit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DFunDef false "emit" ((PCon "Ok" (PVar "out"))) (EApp (EVar "putStr") (EVar "out")))
(DTypeSig false "isEmptyStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isEmptyStrs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyStrs" (PWild) (EVar "False"))
(DTypeSig false "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "runGateCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: list, run)"))))))
(DData Public "GateResult" () ((variant "GateResult" (ConNamed (field "name" (TyCon "String")) (field "script" (TyCon "String")) (field "shell" (TyCon "String")) (field "exitCode" (TyCon "Int")) (field "timedOut" (TyCon "Bool")) (field "spawnError" (TyCon "String")) (field "seconds" (TyCon "Float")) (field "out" (TyCon "String")) (field "err" (TyCon "String"))))) ())
(DData Private "RunEnv" () ((variant "RunEnv" (ConNamed (field "root" (TyCon "String")) (field "medaka" (TyCon "String")) (field "emitter" (TyCon "String")) (field "scratchRoot" (TyCon "String")) (field "timeoutOverride" (TyCon "Int"))))) ())
(DTypeSig false "timeoutFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "timeoutFor" ((PVar "override") (PVar "cost")) (EIf (EBinOp ">" (EVar "override") (ELit (LInt 0))) (EVar "override") (EIf (EBinOp "==" (EVar "cost") (ELit (LString "cheap"))) (ELit (LInt 300)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "medium"))) (ELit (LInt 900)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "heavy"))) (ELit (LInt 3600)) (EIf (EVar "otherwise") (ELit (LInt 900)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "scratchRootOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "scratchRootOf" (PWild) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "TMPDIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EBinOp "/=" (EApp (EVar "stripSlash") (EVar "t")) (ELit (LString "/tmp")))) (EVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_SCRATCH"))) (ELit (LString "/var/tmp/medaka-scratch")))))))
(DTypeSig false "stripSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSlash" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "/")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeGateScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeGateScratch" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "root"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/medaka_gate_XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "d") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "d")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))))
(DTypeSig false "cleanupScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupScratch" ((PVar "dir")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "runCommand") (ELit (LString "rm"))) (EListLit (ELit (LString "-rf")) (EVar "dir")))) (DoExpr (ELit LUnit))))
(DTypeSig false "hasSourceExt" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSourceExt" ((PVar "p")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "p")) (EApp (EApp (EVar "endsWith") (ELit (LString ".c"))) (EVar "p"))) (EApp (EApp (EVar "endsWith") (ELit (LString ".h"))) (EVar "p"))))
(DTypeSig false "newestMtimeIn" (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Float")))))
(DFunDef false "newestMtimeIn" ((PVar "path") (PVar "acc")) (EMatch (EApp (EVar "statFile") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "acc")) (arm (PCon "Ok" (PTuple PWild (PVar "isDir") PWild (PVar "mt"))) () (EIf (EVar "isDir") (EMatch (EApp (EVar "listDir") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "acc")) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EApp (EVar "newestMtimeEntries") (EVar "path")) (EVar "names")) (EVar "acc")))) (EIf (EBinOp "&&" (EApp (EVar "hasSourceExt") (EVar "path")) (EBinOp ">" (EVar "mt") (EVar "acc"))) (EVar "mt") (EVar "acc"))))))
(DTypeSig false "newestMtimeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Float"))))))
(DFunDef false "newestMtimeEntries" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "newestMtimeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "newestMtimeEntries") (EVar "dir")) (EVar "rest")) (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (EVar "acc"))))
(DTypeSig false "newestSourceMtime" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "newestSourceMtime" ((PVar "root")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/compiler")))) (ELit (LFloat 0.0)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/stdlib")))) (EVar "a"))) (DoExpr (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/runtime")))) (EVar "b")))))
(DTypeSig false "selectedOracles" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "selectedOracles" ((PList)) (EListLit))
(DFunDef false "selectedOracles" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EFieldAccess (EVar "g") "oracles") (EApp (EVar "selectedOracles") (EVar "gs"))))
(DTypeSig false "staleOf" (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "staleOf" (PWild PWild (PList)) (EListLit))
(DFunDef false "staleOf" ((PVar "root") (PVar "newest") (PCons (PVar "o") (PVar "os"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "os"))) (DoExpr (EMatch (EApp (EVar "statFile") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/test/bin/"))) (EApp (EVar "display") (EVar "o"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EVar "rest")) (arm (PCon "Ok" (PTuple PWild PWild PWild (PVar "mt"))) () (EIf (EBinOp "<" (EVar "mt") (EVar "newest")) (EBinOp "::" (EVar "o") (EVar "rest")) (EVar "rest")))))))
(DTypeSig false "indentedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "indentedNames" ((PList)) (EListLit))
(DFunDef false "indentedNames" ((PCons (PVar "o") (PVar "os"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "o"))) (ELit (LString ""))) (EApp (EVar "indentedNames") (EVar "os"))))
(DTypeSig false "staleBannerLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "staleBannerLines" ((PList)) (EListLit))
(DFunDef false "staleBannerLines" ((PCons (PVar "o") (PVar "os"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one ")) (EApp (EVar "display") (EVar "o"))) (ELit (LString ""))) (EApp (EVar "staleBannerLines") (EVar "os"))))
(DTypeSig false "staleBanner" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "staleBanner" ((PVar "stale")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "════════════════════════════════════════════════════════════════════")) (EBinOp "++" (EBinOp "++" (ELit (LString "STALE ORACLES (")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "stale"))))) (ELit (LString ") — REFUSING TO RUN."))) (ELit (LString "")) (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "stale"))) (ELit (LString "")) (ELit (LString "These probe binaries are OLDER than compiler/ stdlib/ runtime/ source.")) (ELit (LString "A gate reading one is testing a compiler that no longer exists — and it")) (ELit (LString "reports an ordinary-looking FAIL that is INDISTINGUISHABLE from a real")) (ELit (LString "regression.")) (ELit (LString "")) (ELit (LString "Rebuild ONLY what is stale — one probe per command:"))) (EApp (EVar "staleBannerLines") (EVar "stale"))) (EListLit (ELit (LString "")) (ELit (LString "(Override with NO_STALE_CHECK=1, --no-stale-check, or CI=1 only if you")) (ELit (LString " know exactly why.  This check is skipped in CI on purpose — see the")) (ELit (LString " comment above staleOf.)")) (ELit (LString "════════════════════════════════════════════════════════════════════")) (ELit (LString ""))))))
(DTypeSig false "envSet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "envSet" ((PVar "name")) (EBinOp "/=" (EApp (EApp (EVar "envOr") (EVar "name")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig false "staleRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "staleRefusal" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "staleRefusal" ((PCon "False") (PVar "root") (PVar "gs")) (EIf (EBinOp "||" (EApp (EVar "envSet") (ELit (LString "CI"))) (EApp (EVar "envSet") (ELit (LString "NO_STALE_CHECK")))) (EVar "None") (EBlock (DoLet false false (PVar "names") (EApp (EVar "sortUniqS") (EApp (EVar "selectedOracles") (EVar "gs")))) (DoLet false false (PVar "newest") (EApp (EVar "newestSourceMtime") (EVar "root"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "names")) (arm (PList) () (EVar "None")) (arm (PVar "stale") () (EApp (EVar "Some") (EApp (EVar "staleBanner") (EVar "stale")))))))))
(DTypeSig false "shellFor" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "shellFor" ((PVar "script")) (EMatch (EApp (EVar "readFile") (EVar "script")) (arm (PCon "Err" PWild) () (ELit (LString "sh"))) (arm (PCon "Ok" (PVar "src")) () (EIf (EApp (EApp (EVar "substrIn") (ELit (LString "bash"))) (EApp (EVar "firstLineOf") (EVar "src"))) (ELit (LString "bash")) (ELit (LString "sh"))))))
(DTypeSig false "firstLineOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstLineOf" ((PVar "s")) (EMatch (EApp (EVar "splitNl") (EVar "s")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "l") PWild) () (EVar "l"))))
(DTypeSig false "substrIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substrIn" ((PVar "needle") (PVar "hay")) (EApp (EApp (EApp (EApp (EVar "substrAt") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "hay")) (EApp (EVar "stringLength") (EVar "needle")))))
(DTypeSig false "substrAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "substrAt" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "last")) (EIf (EBinOp ">" (EVar "i") (EVar "last")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "substrAt") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "last")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "gateArgs" (TyFun (TyCon "RunEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gateArgs" ((PVar "env") (PVar "scratch") (PVar "secs") (PVar "sh") (PVar "script")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "medaka"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "emitter"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "TMPDIR=")) (EApp (EVar "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_SCRATCH=")) (EApp (EVar "display") (EVar "scratch"))) (ELit (LString ""))) (ELit (LString "JOBS=1")) (ELit (LString "timeout")) (ELit (LString "-k")) (ELit (LString "5s")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "s"))) (EVar "sh") (EVar "script")))
(DTypeSig false "spawnFailure" (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyCon "GateResult"))))))
(DFunDef false "spawnFailure" ((PVar "g") (PVar "script") (PVar "msg") (PVar "dt")) (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (ELit (LString "sh"))) (fa "exitCode" (ELit (LInt 127))) (fa "timedOut" (EVar "False")) (fa "spawnError" (EVar "msg")) (fa "seconds" (EVar "dt")) (fa "out" (ELit (LString ""))) (fa "err" (ELit (LString ""))))))
(DTypeSig false "runOneGate" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "GateResult")))))
(DFunDef false "runOneGate" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "script"))) (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "gate script not found (registry `run` field): ")) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (ELit (LFloat 0.0))) (EBlock (DoLet false false (PVar "sh") (EApp (EVar "shellFor") (EVar "script"))) (DoLet false false (PVar "secs") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))) (DoExpr (EMatch (EApp (EVar "makeGateScratch") (EFieldAccess (EVar "env") "scratchRoot")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not create a scratch dir: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LFloat 0.0)))) (arm (PCon "Ok" (PVar "scratch")) () (EBlock (DoLet false false (PVar "t0") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EApp (EApp (EApp (EApp (EApp (EVar "gateArgs") (EVar "env")) (EVar "scratch")) (EVar "secs")) (EVar "sh")) (EVar "script")))) (DoLet false false (PVar "dt") (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "t0"))) (DoLet false false PWild (EApp (EVar "cleanupScratch") (EVar "scratch"))) (DoExpr (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not spawn the gate: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "dt"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (EVar "sh")) (fa "exitCode" (EVar "code")) (fa "timedOut" (EBinOp "||" (EBinOp "==" (EVar "code") (ELit (LInt 124))) (EBinOp "==" (EVar "code") (ELit (LInt 137))))) (fa "spawnError" (ELit (LString ""))) (fa "seconds" (EVar "dt")) (fa "out" (EVar "out")) (fa "err" (EVar "errOut"))))))))))))))))
(DTypeSig false "gateOk" (TyFun (TyCon "GateResult") (TyCon "Bool")))
(DFunDef false "gateOk" ((PVar "r")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0)))))
(DTypeSig false "msOf" (TyFun (TyCon "GateResult") (TyCon "Int")))
(DFunDef false "msOf" ((PVar "r")) (EApp (EVar "floatToInt") (EBinOp "*" (EFieldAccess (EVar "r") "seconds") (ELit (LFloat 1000.0)))))
(DTypeSig false "resultLine" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "resultLine" ((PVar "r")) (EIf (EBinOp "/=" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EVar "display") (EFieldAccess (EVar "r") "spawnError"))) (ELit (LString ")\n"))) (EIf (EFieldAccess (EVar "r") "timedOut") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TIMEOUT ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString " after "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PASS  ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "runGatesLoop" (TyFun (TyCon "RunEnv") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "GateResult")))))))
(DFunDef false "runGatesLoop" (PWild (PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "runGatesLoop" ((PVar "env") (PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "runOneGate") (EVar "env")) (EVar "g"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "resultLine") (EVar "r")))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "runGatesLoop") (EVar "env")) (EVar "gs")) (EBinOp "::" (EVar "r") (EVar "acc"))))))
(DTypeSig false "afterNewlines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "afterNewlines" ((PVar "cs") (PVar "i") (PVar "len") (PVar "want")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "<=" (EVar "want") (ELit (LInt 0))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "-" (EVar "want") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "want")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "tailLines" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "tailLines" ((PVar "n") (PVar "s")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "listLen") (EApp (EVar "splitNl") (EVar "s")))) (DoExpr (EIf (EBinOp "<=" (EVar "k") (EVar "n")) (EVar "s") (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "-" (EVar "k") (EVar "n")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))))))
(DTypeSig false "failureDetail" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "failureDetail" ((PVar "r")) (EBlock (DoLet false false (PVar "hdr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n───── ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString " — "))) (EApp (EVar "display") (EFieldAccess (EVar "r") "shell"))) (ELit (LString " "))) (EApp (EVar "display") (EFieldAccess (EVar "r") "script"))) (ELit (LString " (exit "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ") ─────\n")))) (DoLet false false (PVar "o") (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EFieldAccess (EVar "r") "out")) (ELit (LString ""))) (ELit (LString "  (stdout: empty)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ── stdout ──\n")) (EApp (EVar "display") (EApp (EApp (EVar "tailLines") (ELit (LInt 200))) (EFieldAccess (EVar "r") "out")))) (ELit (LString "\n"))))) (DoLet false false (PVar "e") (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EFieldAccess (EVar "r") "err")) (ELit (LString ""))) (ELit (LString "  (stderr: empty)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ── stderr ──\n")) (EApp (EVar "display") (EApp (EApp (EVar "tailLines") (ELit (LInt 200))) (EFieldAccess (EVar "r") "err")))) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "hdr"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "o"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))))
(DTypeSig false "failureDetails" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String")))
(DFunDef false "failureDetails" ((PList)) (ELit (LString "")))
(DFunDef false "failureDetails" ((PCons (PVar "r") (PVar "rs"))) (EIf (EApp (EVar "gateOk") (EVar "r")) (EApp (EVar "failureDetails") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EVar "failureDetail") (EVar "r")) (EApp (EVar "failureDetails") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countOk" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "Int")))
(DFunDef false "countOk" ((PList)) (ELit (LInt 0)))
(DFunDef false "countOk" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "+" (EIf (EApp (EVar "gateOk") (EVar "r")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countOk") (EVar "rs"))))
(DTypeSig false "failingNames" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "failingNames" ((PList)) (EListLit))
(DFunDef false "failingNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EApp (EVar "gateOk") (EVar "r")) (EApp (EVar "failingNames") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "r") "name") (EApp (EVar "failingNames") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resultJson" (TyFun (TyCon "GateResult") (TyCon "Json")))
(DFunDef false "resultJson" ((PVar "r")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "name"))) (ETuple (ELit (LString "script")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "script"))) (ETuple (ELit (LString "shell")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "shell"))) (ETuple (ELit (LString "exit")) (EApp (EVar "JInt") (EFieldAccess (EVar "r") "exitCode"))) (ETuple (ELit (LString "timedOut")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "timedOut"))) (ETuple (ELit (LString "ms")) (EApp (EVar "JInt") (EApp (EVar "msOf") (EVar "r")))) (ETuple (ELit (LString "seconds")) (EApp (EVar "JFloat") (EFieldAccess (EVar "r") "seconds"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EVar "gateOk") (EVar "r")))) (ETuple (ELit (LString "spawnError")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "spawnError"))) (ETuple (ELit (LString "stdout")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "out"))) (ETuple (ELit (LString "stderr")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "err"))))))
(DTypeSig true "runReportJson" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "runReportJson" ((PVar "jobs") (PVar "rs")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jobs")) (EApp (EVar "JInt") (EVar "jobs"))) (ETuple (ELit (LString "parallel")) (EApp (EVar "JBool") (EVar "False"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JInt") (EApp (EVar "countOk") (EVar "rs")))) (ETuple (ELit (LString "failing")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EApp (EVar "countOk") (EVar "rs"))))) (ETuple (ELit (LString "gates")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "resultJson")) (EVar "rs"))))))))
(DTypeSig false "dryLine" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLine" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoLet false false (PVar "sh") (EIf (EApp (EVar "fileExists") (EVar "script")) (EApp (EVar "shellFor") (EVar "script")) (ELit (LString "sh")))) (DoLet false false (PVar "orc") (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "oracles")) (ELit (LString "-")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "g") "oracles")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "sh"))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "script"))) (ELit (LString "\ttimeout="))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s\toracles="))) (EApp (EVar "display") (EVar "orc"))) (ELit (LString "\n"))))))
(DTypeSig false "dryLines" (TyFun (TyCon "RunEnv") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLines" (PWild (PList)) (ELit (LString "")))
(DFunDef false "dryLines" ((PVar "env") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "dryLine") (EVar "env")) (EVar "g")) (EApp (EApp (EVar "dryLines") (EVar "env")) (EVar "gs"))))
(DData Private "RunArgs" () ((variant "RunArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String"))) (field "dryRun" (TyCon "Bool")) (field "json" (TyCon "Bool")) (field "report" (TyApp (TyCon "Option") (TyCon "String"))) (field "timeoutSecs" (TyCon "Int")) (field "jobs" (TyCon "Int")) (field "noStaleCheck" (TyCon "Bool"))))) ())
(DTypeSig false "parseRunArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "RunArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunArgs")))))
(DFunDef false "parseRunArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "RunArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--dry-run")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "dryRun" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--no-stale-check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "noStaleCheck" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --registry needs a path"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--report")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "report" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--report")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --report needs a path"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--timeout")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --timeout needs a whole number of seconds, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "timeoutSecs" (EVar "n"))))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--timeout")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --timeout needs a number of seconds"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--jobs")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --jobs needs a whole number, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "jobs" (EVar "n"))))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--jobs")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --jobs needs a number"))))
(DFunDef false "parseRunArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: unknown flag: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "emptyRunArgs" (TyCon "RunArgs"))
(DFunDef false "emptyRunArgs" () (ERecordCreate "RunArgs" ((fa "registry" (EVar "None")) (fa "selectors" (EListLit)) (fa "dryRun" (EVar "False")) (fa "json" (EVar "False")) (fa "report" (EVar "None")) (fa "timeoutSecs" (ELit (LInt 0))) (fa "jobs" (ELit (LInt 1))) (fa "noStaleCheck" (EVar "False")))))
(DTypeSig false "selectFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "selectFor" ((PVar "path") (PVar "tokens") (PVar "sels") (PVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates")) (arm (PList) () (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: no gates match: ")) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))))) (arm (PVar "sel") () (EApp (EVar "Ok") (EVar "sel")))))))
(DTypeSig false "runEnvFor" (TyFun (TyCon "RunArgs") (TyEffect ("IO") None (TyCon "RunEnv"))))
(DFunDef false "runEnvFor" ((PVar "a")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (ERecordCreate "RunEnv" ((fa "root" (EVar "root")) (fa "medaka" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/medaka"))))) (fa "emitter" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/medaka_emitter"))))) (fa "scratchRoot" (EApp (EVar "scratchRootOf") (ELit LUnit))) (fa "timeoutOverride" (EFieldAccess (EVar "a") "timeoutSecs")))))))
(DTypeSig false "writeReport" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "writeReport" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "writeReport" ((PCon "Some" (PVar "p")) (PVar "body")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "p")) (EVar "body")) (arm (PCon "Err" (PVar "m")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: could not write --report ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EVar "True"))))
(DTypeSig false "summaryLine" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "summaryLine" ((PVar "jobs") (PVar "rs")) (EBlock (DoLet false false (PVar "ok") (EApp (EVar "countOk") (EVar "rs"))) (DoLet false false (PVar "bad") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EVar "ok"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n=== gate run: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ok")))) (ELit (LString " ok, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "bad")))) (ELit (LString " failing ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " gates, --jobs "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "jobs")))) (ELit (LString " requested, run SEQUENTIALLY) ===\n"))))))
(DTypeSig false "finishRun" (TyFun (TyCon "RunArgs") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "finishRun" ((PVar "a") (PVar "rs")) (EBlock (DoLet false false (PVar "wrote") (EApp (EApp (EVar "writeReport") (EFieldAccess (EVar "a") "report")) (EBinOp "++" (EApp (EApp (EVar "runReportJson") (EFieldAccess (EVar "a") "jobs")) (EVar "rs")) (ELit (LString "\n"))))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (EApp (EVar "putStr") (EBinOp "++" (EApp (EApp (EVar "runReportJson") (EFieldAccess (EVar "a") "jobs")) (EVar "rs")) (ELit (LString "\n")))) (ELit LUnit))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (ELit LUnit) (EApp (EVar "putStr") (EApp (EVar "failureDetails") (EVar "rs"))))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (ELit LUnit) (EApp (EVar "putStr") (EApp (EApp (EVar "summaryLine") (EFieldAccess (EVar "a") "jobs")) (EVar "rs"))))) (DoLet false false (PVar "bad") (EApp (EVar "failingNames") (EVar "rs"))) (DoLet false false PWild (EIf (EBinOp "||" (EFieldAccess (EVar "a") "json") (EApp (EVar "isEmptyStrs") (EVar "bad"))) (ELit LUnit) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "FAILING: ")) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "\n")))))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyStrs") (EVar "bad")) (EVar "wrote")) (EApp (EVar "exit") (ELit (LInt 0))) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runSelected" (TyFun (TyCon "RunArgs") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runSelected" ((PVar "a") (PVar "gs")) (EBlock (DoLet false false (PVar "env") (EApp (EVar "runEnvFor") (EVar "a"))) (DoExpr (EIf (EFieldAccess (EVar "a") "dryRun") (EApp (EVar "putStr") (EApp (EApp (EVar "dryLines") (EVar "env")) (EVar "gs"))) (EMatch (EApp (EApp (EApp (EVar "staleRefusal") (EFieldAccess (EVar "a") "noStaleCheck")) (EFieldAccess (EVar "env") "root")) (EVar "gs")) (arm (PCon "Some" (PVar "banner")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "banner"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EApp (EApp (EVar "finishRun") (EVar "a")) (EApp (EApp (EApp (EVar "runGatesLoop") (EVar "env")) (EVar "gs")) (EListLit)))))))))
(DTypeSig false "runRunCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseRunArgs") (EVar "argv")) (EVar "emptyRunArgs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectFor") (EVar "path")) (EFieldAccess (EVar "a") "selectors")) (EVar "sels")) (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "gs")) () (EApp (EApp (EVar "runSelected") (EVar "a")) (EVar "gs")))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "endsWith" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DTypeSig false "globMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globMatchAt" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EBinOp ">=" (EVar "pi") (EVar "pn")) (EBinOp ">=" (EVar "si") (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "?"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "globStar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globStar" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EVar "True") (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "stringToChars") (EVar "pat"))) (DoLet false false (PVar "subj") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "p")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "p"))) (EVar "subj")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "subj"))))))
(DData Public "Selector" () ((variant "SelName" (ConPos (TyCon "String"))) (variant "SelArea" (ConPos (TyCon "String"))) (variant "SelProject" (ConPos (TyCon "String"))) (variant "SelTier" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Selector")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SelName" (PVar "__a0")) (PCon "SelName" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelArea" (PVar "__a0")) (PCon "SelArea" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelProject" (PVar "__a0")) (PCon "SelProject" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelTier" (PVar "__a0")) (PCon "SelTier" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Selector")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SelName" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelName ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelArea" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelArea ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelProject" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelProject ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelTier" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelTier ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig false "selPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "selPrefix" ((PVar "pre") (PVar "tok")) (EBlock (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "tok")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "tok")) (EVar "pre"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))) (EVar "None")))))
(DTypeSig false "hasColon" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasColon" ((PVar "tok")) (EApp (EApp (EVar "colonAt") (EApp (EVar "stringToChars") (EVar "tok"))) (ELit (LInt 0))))
(DTypeSig false "colonAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "colonAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ":"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "colonAt") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "parseSelector" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Selector"))))
(DFunDef false "parseSelector" ((PVar "tok")) (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "name:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "area:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelArea") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "project:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelProject") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "tier:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelTier") (EVar "v")))) (arm (PCon "None") () (EIf (EApp (EVar "hasColon") (EVar "tok")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown selector field in '")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' (expected name:, area:, project: or tier:)")))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "tok")))))))))))))
(DTypeSig true "matchesSelector" (TyFun (TyCon "Selector") (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesSelector" ((PCon "SelName" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "name")))
(DFunDef false "matchesSelector" ((PCon "SelArea" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "area")))
(DFunDef false "matchesSelector" ((PCon "SelProject" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "project")))
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "tier")))
(DTypeSig false "matchesAll" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesAll" ((PList) PWild) (EVar "True"))
(DFunDef false "matchesAll" ((PCons (PVar "s") (PVar "ss")) (PVar "g")) (EBinOp "&&" (EApp (EApp (EVar "matchesSelector") (EVar "s")) (EVar "g")) (EApp (EApp (EVar "matchesAll") (EVar "ss")) (EVar "g"))))
(DTypeSig true "selectGates" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "selectGates" (PWild (PList)) (EListLit))
(DFunDef false "selectGates" ((PVar "sels") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "matchesAll") (EVar "sels")) (EVar "g")) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run  [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                   [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                   [--registry <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` and `gate explain` are not implemented yet\n")) (ELit (LString "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate list: --registry needs a path"))))
(DFunDef false "parseListArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: unknown flag: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "parseSelectors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Selector"))))))
(DFunDef false "parseSelectors" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseSels") (EVar "acc")) (EListLit))))
(DFunDef false "parseSelectors" ((PCons (PVar "t") (PVar "ts")) (PVar "acc")) (EMatch (EApp (EVar "parseSelector") (EVar "t")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "parseSelectors") (EVar "ts")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "reverseSels" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyCon "List") (TyCon "Selector")))))
(DFunDef false "reverseSels" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseSels" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseSels") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "registryPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "registryPath" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "registryPath" ((PCon "None")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gates.toml"))))))
(DTypeSig false "listOutput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path")))))))))))))
(DTypeSig false "selectionOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "selectionOutput" (PWild (PVar "tokens") (PList) (PVar "path")) (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: no gates match: ")) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "selectionOutput" ((PVar "isJson") PWild (PCons (PVar "g") (PVar "gs")) PWild) (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderJson") (EBinOp "::" (EVar "g") (EVar "gs"))) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderNames") (EBinOp "::" (EVar "g") (EVar "gs"))))))
(DTypeSig false "emit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DFunDef false "emit" ((PCon "Ok" (PVar "out"))) (EApp (EVar "putStr") (EVar "out")))
(DTypeSig false "isEmptyStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isEmptyStrs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyStrs" (PWild) (EVar "False"))
(DTypeSig false "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "runGateCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: list, run)"))))))
(DData Public "GateResult" () ((variant "GateResult" (ConNamed (field "name" (TyCon "String")) (field "script" (TyCon "String")) (field "shell" (TyCon "String")) (field "exitCode" (TyCon "Int")) (field "timedOut" (TyCon "Bool")) (field "spawnError" (TyCon "String")) (field "seconds" (TyCon "Float")) (field "out" (TyCon "String")) (field "err" (TyCon "String"))))) ())
(DData Private "RunEnv" () ((variant "RunEnv" (ConNamed (field "root" (TyCon "String")) (field "medaka" (TyCon "String")) (field "emitter" (TyCon "String")) (field "scratchRoot" (TyCon "String")) (field "timeoutOverride" (TyCon "Int"))))) ())
(DTypeSig false "timeoutFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "timeoutFor" ((PVar "override") (PVar "cost")) (EIf (EBinOp ">" (EVar "override") (ELit (LInt 0))) (EVar "override") (EIf (EBinOp "==" (EVar "cost") (ELit (LString "cheap"))) (ELit (LInt 300)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "medium"))) (ELit (LInt 900)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "heavy"))) (ELit (LInt 3600)) (EIf (EVar "otherwise") (ELit (LInt 900)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "scratchRootOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "scratchRootOf" (PWild) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "TMPDIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EBinOp "/=" (EApp (EVar "stripSlash") (EVar "t")) (ELit (LString "/tmp")))) (EVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_SCRATCH"))) (ELit (LString "/var/tmp/medaka-scratch")))))))
(DTypeSig false "stripSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSlash" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "/")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeGateScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeGateScratch" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "root"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/medaka_gate_XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "d") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "d")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))))
(DTypeSig false "cleanupScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupScratch" ((PVar "dir")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "runCommand") (ELit (LString "rm"))) (EListLit (ELit (LString "-rf")) (EVar "dir")))) (DoExpr (ELit LUnit))))
(DTypeSig false "hasSourceExt" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSourceExt" ((PVar "p")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "p")) (EApp (EApp (EVar "endsWith") (ELit (LString ".c"))) (EVar "p"))) (EApp (EApp (EVar "endsWith") (ELit (LString ".h"))) (EVar "p"))))
(DTypeSig false "newestMtimeIn" (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Float")))))
(DFunDef false "newestMtimeIn" ((PVar "path") (PVar "acc")) (EMatch (EApp (EVar "statFile") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "acc")) (arm (PCon "Ok" (PTuple PWild (PVar "isDir") PWild (PVar "mt"))) () (EIf (EVar "isDir") (EMatch (EApp (EVar "listDir") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "acc")) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EApp (EVar "newestMtimeEntries") (EVar "path")) (EVar "names")) (EVar "acc")))) (EIf (EBinOp "&&" (EApp (EVar "hasSourceExt") (EVar "path")) (EBinOp ">" (EVar "mt") (EVar "acc"))) (EVar "mt") (EVar "acc"))))))
(DTypeSig false "newestMtimeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Float"))))))
(DFunDef false "newestMtimeEntries" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "newestMtimeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "newestMtimeEntries") (EVar "dir")) (EVar "rest")) (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (EVar "acc"))))
(DTypeSig false "newestSourceMtime" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "newestSourceMtime" ((PVar "root")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/compiler")))) (ELit (LFloat 0.0)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/stdlib")))) (EVar "a"))) (DoExpr (EApp (EApp (EVar "newestMtimeIn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/runtime")))) (EVar "b")))))
(DTypeSig false "selectedOracles" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "selectedOracles" ((PList)) (EListLit))
(DFunDef false "selectedOracles" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EFieldAccess (EVar "g") "oracles") (EApp (EVar "selectedOracles") (EVar "gs"))))
(DTypeSig false "staleOf" (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "staleOf" (PWild PWild (PList)) (EListLit))
(DFunDef false "staleOf" ((PVar "root") (PVar "newest") (PCons (PVar "o") (PVar "os"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "os"))) (DoExpr (EMatch (EApp (EVar "statFile") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/test/bin/"))) (EApp (EMethodRef "display") (EVar "o"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EVar "rest")) (arm (PCon "Ok" (PTuple PWild PWild PWild (PVar "mt"))) () (EIf (EBinOp "<" (EVar "mt") (EVar "newest")) (EBinOp "::" (EVar "o") (EVar "rest")) (EVar "rest")))))))
(DTypeSig false "indentedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "indentedNames" ((PList)) (EListLit))
(DFunDef false "indentedNames" ((PCons (PVar "o") (PVar "os"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "o"))) (ELit (LString ""))) (EApp (EVar "indentedNames") (EVar "os"))))
(DTypeSig false "staleBannerLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "staleBannerLines" ((PList)) (EListLit))
(DFunDef false "staleBannerLines" ((PCons (PVar "o") (PVar "os"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one ")) (EApp (EMethodRef "display") (EVar "o"))) (ELit (LString ""))) (EApp (EVar "staleBannerLines") (EVar "os"))))
(DTypeSig false "staleBanner" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "staleBanner" ((PVar "stale")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "════════════════════════════════════════════════════════════════════")) (EBinOp "++" (EBinOp "++" (ELit (LString "STALE ORACLES (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "stale"))))) (ELit (LString ") — REFUSING TO RUN."))) (ELit (LString "")) (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "stale"))) (ELit (LString "")) (ELit (LString "These probe binaries are OLDER than compiler/ stdlib/ runtime/ source.")) (ELit (LString "A gate reading one is testing a compiler that no longer exists — and it")) (ELit (LString "reports an ordinary-looking FAIL that is INDISTINGUISHABLE from a real")) (ELit (LString "regression.")) (ELit (LString "")) (ELit (LString "Rebuild ONLY what is stale — one probe per command:"))) (EApp (EVar "staleBannerLines") (EVar "stale"))) (EListLit (ELit (LString "")) (ELit (LString "(Override with NO_STALE_CHECK=1, --no-stale-check, or CI=1 only if you")) (ELit (LString " know exactly why.  This check is skipped in CI on purpose — see the")) (ELit (LString " comment above staleOf.)")) (ELit (LString "════════════════════════════════════════════════════════════════════")) (ELit (LString ""))))))
(DTypeSig false "envSet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "envSet" ((PVar "name")) (EBinOp "/=" (EApp (EApp (EVar "envOr") (EVar "name")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig false "staleRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "staleRefusal" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "staleRefusal" ((PCon "False") (PVar "root") (PVar "gs")) (EIf (EBinOp "||" (EApp (EVar "envSet") (ELit (LString "CI"))) (EApp (EVar "envSet") (ELit (LString "NO_STALE_CHECK")))) (EVar "None") (EBlock (DoLet false false (PVar "names") (EApp (EVar "sortUniqS") (EApp (EVar "selectedOracles") (EVar "gs")))) (DoLet false false (PVar "newest") (EApp (EVar "newestSourceMtime") (EVar "root"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "names")) (arm (PList) () (EVar "None")) (arm (PVar "stale") () (EApp (EVar "Some") (EApp (EVar "staleBanner") (EVar "stale")))))))))
(DTypeSig false "shellFor" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "shellFor" ((PVar "script")) (EMatch (EApp (EVar "readFile") (EVar "script")) (arm (PCon "Err" PWild) () (ELit (LString "sh"))) (arm (PCon "Ok" (PVar "src")) () (EIf (EApp (EApp (EVar "substrIn") (ELit (LString "bash"))) (EApp (EVar "firstLineOf") (EVar "src"))) (ELit (LString "bash")) (ELit (LString "sh"))))))
(DTypeSig false "firstLineOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstLineOf" ((PVar "s")) (EMatch (EApp (EVar "splitNl") (EVar "s")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "l") PWild) () (EVar "l"))))
(DTypeSig false "substrIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substrIn" ((PVar "needle") (PVar "hay")) (EApp (EApp (EApp (EApp (EVar "substrAt") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "hay")) (EApp (EVar "stringLength") (EVar "needle")))))
(DTypeSig false "substrAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "substrAt" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "last")) (EIf (EBinOp ">" (EVar "i") (EVar "last")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "substrAt") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "last")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "gateArgs" (TyFun (TyCon "RunEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gateArgs" ((PVar "env") (PVar "scratch") (PVar "secs") (PVar "sh") (PVar "script")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "medaka"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "emitter"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "TMPDIR=")) (EApp (EMethodRef "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_SCRATCH=")) (EApp (EMethodRef "display") (EVar "scratch"))) (ELit (LString ""))) (ELit (LString "JOBS=1")) (ELit (LString "timeout")) (ELit (LString "-k")) (ELit (LString "5s")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "s"))) (EVar "sh") (EVar "script")))
(DTypeSig false "spawnFailure" (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyCon "GateResult"))))))
(DFunDef false "spawnFailure" ((PVar "g") (PVar "script") (PVar "msg") (PVar "dt")) (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (ELit (LString "sh"))) (fa "exitCode" (ELit (LInt 127))) (fa "timedOut" (EVar "False")) (fa "spawnError" (EVar "msg")) (fa "seconds" (EVar "dt")) (fa "out" (ELit (LString ""))) (fa "err" (ELit (LString ""))))))
(DTypeSig false "runOneGate" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "GateResult")))))
(DFunDef false "runOneGate" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "script"))) (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "gate script not found (registry `run` field): ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (ELit (LFloat 0.0))) (EBlock (DoLet false false (PVar "sh") (EApp (EVar "shellFor") (EVar "script"))) (DoLet false false (PVar "secs") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))) (DoExpr (EMatch (EApp (EVar "makeGateScratch") (EFieldAccess (EVar "env") "scratchRoot")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not create a scratch dir: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LFloat 0.0)))) (arm (PCon "Ok" (PVar "scratch")) () (EBlock (DoLet false false (PVar "t0") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EApp (EApp (EApp (EApp (EApp (EVar "gateArgs") (EVar "env")) (EVar "scratch")) (EVar "secs")) (EVar "sh")) (EVar "script")))) (DoLet false false (PVar "dt") (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "t0"))) (DoLet false false PWild (EApp (EVar "cleanupScratch") (EVar "scratch"))) (DoExpr (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not spawn the gate: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "dt"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (EVar "sh")) (fa "exitCode" (EVar "code")) (fa "timedOut" (EBinOp "||" (EBinOp "==" (EVar "code") (ELit (LInt 124))) (EBinOp "==" (EVar "code") (ELit (LInt 137))))) (fa "spawnError" (ELit (LString ""))) (fa "seconds" (EVar "dt")) (fa "out" (EVar "out")) (fa "err" (EVar "errOut"))))))))))))))))
(DTypeSig false "gateOk" (TyFun (TyCon "GateResult") (TyCon "Bool")))
(DFunDef false "gateOk" ((PVar "r")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0)))))
(DTypeSig false "msOf" (TyFun (TyCon "GateResult") (TyCon "Int")))
(DFunDef false "msOf" ((PVar "r")) (EApp (EVar "floatToInt") (EBinOp "*" (EFieldAccess (EVar "r") "seconds") (ELit (LFloat 1000.0)))))
(DTypeSig false "resultLine" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "resultLine" ((PVar "r")) (EIf (EBinOp "/=" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "spawnError"))) (ELit (LString ")\n"))) (EIf (EFieldAccess (EVar "r") "timedOut") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TIMEOUT ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString " after "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PASS  ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "runGatesLoop" (TyFun (TyCon "RunEnv") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "GateResult")))))))
(DFunDef false "runGatesLoop" (PWild (PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "runGatesLoop" ((PVar "env") (PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "runOneGate") (EVar "env")) (EVar "g"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "resultLine") (EVar "r")))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "runGatesLoop") (EVar "env")) (EVar "gs")) (EBinOp "::" (EVar "r") (EVar "acc"))))))
(DTypeSig false "afterNewlines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "afterNewlines" ((PVar "cs") (PVar "i") (PVar "len") (PVar "want")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "<=" (EVar "want") (ELit (LInt 0))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "-" (EVar "want") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "want")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "tailLines" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "tailLines" ((PVar "n") (PVar "s")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "listLen") (EApp (EVar "splitNl") (EVar "s")))) (DoExpr (EIf (EBinOp "<=" (EVar "k") (EVar "n")) (EVar "s") (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EApp (EVar "afterNewlines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "-" (EVar "k") (EVar "n")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))))))
(DTypeSig false "failureDetail" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "failureDetail" ((PVar "r")) (EBlock (DoLet false false (PVar "hdr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n───── ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString " — "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "shell"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "script"))) (ELit (LString " (exit "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ") ─────\n")))) (DoLet false false (PVar "o") (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EFieldAccess (EVar "r") "out")) (ELit (LString ""))) (ELit (LString "  (stdout: empty)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ── stdout ──\n")) (EApp (EMethodRef "display") (EApp (EApp (EVar "tailLines") (ELit (LInt 200))) (EFieldAccess (EVar "r") "out")))) (ELit (LString "\n"))))) (DoLet false false (PVar "e") (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EFieldAccess (EVar "r") "err")) (ELit (LString ""))) (ELit (LString "  (stderr: empty)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ── stderr ──\n")) (EApp (EMethodRef "display") (EApp (EApp (EVar "tailLines") (ELit (LInt 200))) (EFieldAccess (EVar "r") "err")))) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "hdr"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "o"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))))
(DTypeSig false "failureDetails" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String")))
(DFunDef false "failureDetails" ((PList)) (ELit (LString "")))
(DFunDef false "failureDetails" ((PCons (PVar "r") (PVar "rs"))) (EIf (EApp (EVar "gateOk") (EVar "r")) (EApp (EVar "failureDetails") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EVar "failureDetail") (EVar "r")) (EApp (EVar "failureDetails") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countOk" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "Int")))
(DFunDef false "countOk" ((PList)) (ELit (LInt 0)))
(DFunDef false "countOk" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "+" (EIf (EApp (EVar "gateOk") (EVar "r")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countOk") (EVar "rs"))))
(DTypeSig false "failingNames" (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "failingNames" ((PList)) (EListLit))
(DFunDef false "failingNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EApp (EVar "gateOk") (EVar "r")) (EApp (EVar "failingNames") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "r") "name") (EApp (EVar "failingNames") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resultJson" (TyFun (TyCon "GateResult") (TyCon "Json")))
(DFunDef false "resultJson" ((PVar "r")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "name"))) (ETuple (ELit (LString "script")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "script"))) (ETuple (ELit (LString "shell")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "shell"))) (ETuple (ELit (LString "exit")) (EApp (EVar "JInt") (EFieldAccess (EVar "r") "exitCode"))) (ETuple (ELit (LString "timedOut")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "timedOut"))) (ETuple (ELit (LString "ms")) (EApp (EVar "JInt") (EApp (EVar "msOf") (EVar "r")))) (ETuple (ELit (LString "seconds")) (EApp (EVar "JFloat") (EFieldAccess (EVar "r") "seconds"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EVar "gateOk") (EVar "r")))) (ETuple (ELit (LString "spawnError")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "spawnError"))) (ETuple (ELit (LString "stdout")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "out"))) (ETuple (ELit (LString "stderr")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "err"))))))
(DTypeSig true "runReportJson" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "runReportJson" ((PVar "jobs") (PVar "rs")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jobs")) (EApp (EVar "JInt") (EVar "jobs"))) (ETuple (ELit (LString "parallel")) (EApp (EVar "JBool") (EVar "False"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JInt") (EApp (EVar "countOk") (EVar "rs")))) (ETuple (ELit (LString "failing")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EApp (EVar "countOk") (EVar "rs"))))) (ETuple (ELit (LString "gates")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "resultJson")) (EVar "rs"))))))))
(DTypeSig false "dryLine" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLine" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoLet false false (PVar "sh") (EIf (EApp (EVar "fileExists") (EVar "script")) (EApp (EVar "shellFor") (EVar "script")) (ELit (LString "sh")))) (DoLet false false (PVar "orc") (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "oracles")) (ELit (LString "-")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "g") "oracles")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "sh"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "script"))) (ELit (LString "\ttimeout="))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s\toracles="))) (EApp (EMethodRef "display") (EVar "orc"))) (ELit (LString "\n"))))))
(DTypeSig false "dryLines" (TyFun (TyCon "RunEnv") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLines" (PWild (PList)) (ELit (LString "")))
(DFunDef false "dryLines" ((PVar "env") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "dryLine") (EVar "env")) (EVar "g")) (EApp (EApp (EVar "dryLines") (EVar "env")) (EVar "gs"))))
(DData Private "RunArgs" () ((variant "RunArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String"))) (field "dryRun" (TyCon "Bool")) (field "json" (TyCon "Bool")) (field "report" (TyApp (TyCon "Option") (TyCon "String"))) (field "timeoutSecs" (TyCon "Int")) (field "jobs" (TyCon "Int")) (field "noStaleCheck" (TyCon "Bool"))))) ())
(DTypeSig false "parseRunArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "RunArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunArgs")))))
(DFunDef false "parseRunArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "RunArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--dry-run")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "dryRun" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--no-stale-check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "noStaleCheck" (EVar "True"))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --registry needs a path"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--report")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "report" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--report")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --report needs a path"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--timeout")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --timeout needs a whole number of seconds, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "timeoutSecs" (EVar "n"))))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--timeout")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --timeout needs a number of seconds"))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--jobs")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --jobs needs a whole number, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "jobs" (EVar "n"))))))))
(DFunDef false "parseRunArgs" ((PCons (PLit (LString "--jobs")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate run: --jobs needs a number"))))
(DFunDef false "parseRunArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: unknown flag: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseRunArgs") (EVar "rest")) (EVariantUpdate "RunArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "emptyRunArgs" (TyCon "RunArgs"))
(DFunDef false "emptyRunArgs" () (ERecordCreate "RunArgs" ((fa "registry" (EVar "None")) (fa "selectors" (EListLit)) (fa "dryRun" (EVar "False")) (fa "json" (EVar "False")) (fa "report" (EVar "None")) (fa "timeoutSecs" (ELit (LInt 0))) (fa "jobs" (ELit (LInt 1))) (fa "noStaleCheck" (EVar "False")))))
(DTypeSig false "selectFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "selectFor" ((PVar "path") (PVar "tokens") (PVar "sels") (PVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates")) (arm (PList) () (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: no gates match: ")) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))))) (arm (PVar "sel") () (EApp (EVar "Ok") (EVar "sel")))))))
(DTypeSig false "runEnvFor" (TyFun (TyCon "RunArgs") (TyEffect ("IO") None (TyCon "RunEnv"))))
(DFunDef false "runEnvFor" ((PVar "a")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (ERecordCreate "RunEnv" ((fa "root" (EVar "root")) (fa "medaka" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/medaka"))))) (fa "emitter" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/medaka_emitter"))))) (fa "scratchRoot" (EApp (EVar "scratchRootOf") (ELit LUnit))) (fa "timeoutOverride" (EFieldAccess (EVar "a") "timeoutSecs")))))))
(DTypeSig false "writeReport" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "writeReport" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "writeReport" ((PCon "Some" (PVar "p")) (PVar "body")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "p")) (EVar "body")) (arm (PCon "Err" (PVar "m")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: could not write --report ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EVar "True"))))
(DTypeSig false "summaryLine" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "summaryLine" ((PVar "jobs") (PVar "rs")) (EBlock (DoLet false false (PVar "ok") (EApp (EVar "countOk") (EVar "rs"))) (DoLet false false (PVar "bad") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EVar "ok"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n=== gate run: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ok")))) (ELit (LString " ok, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "bad")))) (ELit (LString " failing ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " gates, --jobs "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "jobs")))) (ELit (LString " requested, run SEQUENTIALLY) ===\n"))))))
(DTypeSig false "finishRun" (TyFun (TyCon "RunArgs") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "finishRun" ((PVar "a") (PVar "rs")) (EBlock (DoLet false false (PVar "wrote") (EApp (EApp (EVar "writeReport") (EFieldAccess (EVar "a") "report")) (EBinOp "++" (EApp (EApp (EVar "runReportJson") (EFieldAccess (EVar "a") "jobs")) (EVar "rs")) (ELit (LString "\n"))))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (EApp (EVar "putStr") (EBinOp "++" (EApp (EApp (EVar "runReportJson") (EFieldAccess (EVar "a") "jobs")) (EVar "rs")) (ELit (LString "\n")))) (ELit LUnit))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (ELit LUnit) (EApp (EVar "putStr") (EApp (EVar "failureDetails") (EVar "rs"))))) (DoLet false false PWild (EIf (EFieldAccess (EVar "a") "json") (ELit LUnit) (EApp (EVar "putStr") (EApp (EApp (EVar "summaryLine") (EFieldAccess (EVar "a") "jobs")) (EVar "rs"))))) (DoLet false false (PVar "bad") (EApp (EVar "failingNames") (EVar "rs"))) (DoLet false false PWild (EIf (EBinOp "||" (EFieldAccess (EVar "a") "json") (EApp (EVar "isEmptyStrs") (EVar "bad"))) (ELit LUnit) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "FAILING: ")) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "\n")))))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyStrs") (EVar "bad")) (EVar "wrote")) (EApp (EVar "exit") (ELit (LInt 0))) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runSelected" (TyFun (TyCon "RunArgs") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runSelected" ((PVar "a") (PVar "gs")) (EBlock (DoLet false false (PVar "env") (EApp (EVar "runEnvFor") (EVar "a"))) (DoExpr (EIf (EFieldAccess (EVar "a") "dryRun") (EApp (EVar "putStr") (EApp (EApp (EVar "dryLines") (EVar "env")) (EVar "gs"))) (EMatch (EApp (EApp (EApp (EVar "staleRefusal") (EFieldAccess (EVar "a") "noStaleCheck")) (EFieldAccess (EVar "env") "root")) (EVar "gs")) (arm (PCon "Some" (PVar "banner")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "banner"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EApp (EApp (EVar "finishRun") (EVar "a")) (EApp (EApp (EApp (EVar "runGatesLoop") (EVar "env")) (EVar "gs")) (EListLit)))))))))
(DTypeSig false "runRunCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseRunArgs") (EVar "argv")) (EVar "emptyRunArgs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectFor") (EVar "path")) (EFieldAccess (EVar "a") "selectors")) (EVar "sels")) (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "gs")) () (EApp (EApp (EVar "runSelected") (EVar "a")) (EVar "gs")))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
