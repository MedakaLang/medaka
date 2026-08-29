# META
source_lines=2041
stages=DESUGAR,MARK
# SOURCE
{- gate_cmd.mdk — `medaka gate`, the gate-registry driver (#2176, epic #2182).

   Four commands: `medaka gate list [<selector>...] [--json]` (the read path —
   the registry schema `test/gates.toml`, a reader for it, and the selector
   language), `medaka gate run [<selector>...]`, which EXECUTES the selected
   gates, `medaka gate verify` (the drift gate: TEXT-ONLY, no build — every
   gate candidate enrolled-or-ledgered, every entry's `run`/`oracles`/`corpus`
   targets exist, every entry reachable by a selector, every `name` unique)
   and `medaka gate
   explain <path>` (the reverse lookup: which entries does a CHANGED PATH
   select, via which `sources` glob or `corpus` directory, and what the
   registry-level fail-open policy says about it —
   `docs/ops/GATE-REGISTRY-DESIGN.md` §2/§3).

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

import toml.{Toml, parse, getString, getArray, getBool, tableCount, tableEntry}
import json.{Json, JString, JInt, JFloat, JBool, jArray, jObject, stringify}
import driver.build_cmd.{envOr, defaultMedakaRoot}
import support.path.{joinPath}
import support.util.{
  contains,
  endsWith,
  filterList,
  joinNl,
  joinWith,
  listLen,
  parseDecChecked,
  reverseL,
  sortUniqS,
  splitNl,
  splitOnChar,
  startsWith,
  stringTrim,
}

-- ── The entry schema ────────────────────────────────────────────────────────
-- One `[[gate]]` table in `test/gates.toml` per gate.  Every field below is
-- REQUIRED to be present in the file, list fields included: an absent list is
-- an error, not an empty list — a present-and-empty `sources` is a different
-- fact from "this gate has no sources", and the reader must not blur the two
-- by defaulting.
--
-- `shard` (S-1, #2177) is the ci.yml `gates` matrix ROW this gate runs in, or
-- the sentinel `other-job` for a gate some other workflow job schedules.  The
-- row's own options and placement prose live in the sibling `[[shard]]` table
-- (`Shard`, below), not on the entry — they are per-ROW facts, and putting
-- them on 227 entries would be 227 chances for a row to disagree with itself.

public export data Gate =
  | Gate {
      name : String,
      area : String,
      shard : String,
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
    shard <- reqStr i "shard" e
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
        shard = shard,
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

-- ── The `gates` matrix rows ─────────────────────────────────────────────────
-- One `[[shard]]` per row of ci.yml's `gates` job matrix.  A gate's `shard`
-- field names one of these; the row carries what the MATRIX needs and the gate
-- does not — the runner options, and the placement rationale.
--
-- `rationale` is a PATH (`test/gate_shards/<name>.txt`), not the prose itself:
-- the TOML subset this reader is built on has no multi-line string, and 180
-- lines of English on one line would be worse than no home at all.  Nothing
-- here reads that file — `medaka gate list --shards` prints the path, and the
-- ci.yml generator (S-2) is what will read it and emit it verbatim as the
-- row's comment block.

public export data Shard =
  | Shard {
      name : String,
      fullCores : Bool,
      wasmArm : Bool,
      rationale : String,
    }

shardStr : Int -> String -> Toml -> Result String String
shardStr i field entry = match getString field entry
  Some s => Ok s
  None => Err "gates.toml: [[shard]] #\{intToString i}: missing required string field '\{field}'"

-- Present-or-error, like every other field: an ABSENT `wasm_arm` must not
-- silently read as `false`.  In ci.yml the key IS absent when the option is
-- off, but that is the GENERATOR's encoding of `false`, not the registry's —
-- a row that simply forgot the key would otherwise lose its Wasm toolchain
-- and take its gates' Wasm arms down quietly with it.
shardBool : Int -> String -> Toml -> Result String Bool
shardBool i field entry = match getBool field entry
  Some b => Ok b
  None => Err "gates.toml: [[shard]] #\{intToString i}: missing required boolean field '\{field}'"

readShard : Toml -> Int -> Result String Shard
readShard doc i =
  let e = tableEntry "shard" i doc
  do
    name <- shardStr i "name" e
    fullCores <- shardBool i "full_cores" e
    wasmArm <- shardBool i "wasm_arm" e
    rationale <- shardStr i "rationale" e
    Ok
      Shard {
        name = name,
        fullCores = fullCores,
        wasmArm = wasmArm,
        rationale = rationale,
      }

readShardsFrom : Toml -> Int -> Int -> List Shard -> Result String (List Shard)
readShardsFrom doc i n acc
  | i >= n = Ok (reverseShards acc [])
  | otherwise = match readShard doc i
    Err m => Err m
    Ok sh => readShardsFrom doc (i + 1) n (sh::acc)

reverseShards : List Shard -> List Shard -> List Shard
reverseShards [] acc = acc
reverseShards (s::ss) acc = reverseShards ss (s::acc)

{- | Parse a registry's `[[shard]]` rows, in file order.  A registry with no
   rows is an error for the same reason one with no gates is: "the repo
   schedules nothing" must not be a quiet, well-formed answer. -}
export
parseShards : String -> Result String (List Shard)
parseShards src = match parse src
  Err m => Err "gates.toml: \{m}"
  Ok doc =>
    let n = tableCount "shard" doc
    if n == 0 then
      Err "gates.toml: no [[shard]] entries found"
    else
      readShardsFrom doc 0 n []

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
    ("shard", JString g.shard),
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

shardJson : Shard -> Json
shardJson sh = jObject
  [
    ("name", JString sh.name),
    ("full_cores", JBool sh.fullCores),
    ("wasm_arm", JBool sh.wasmArm),
    ("rationale", JString sh.rationale),
  ]

{- | `--shards --json`: the matrix rows as a JSON array, in registry order. -}
export
renderShardsJson : List Shard -> String
renderShardsJson shs = stringify (jArray (map shardJson shs))

boolWord : Bool -> String
boolWord b = if b then "true" else "false"

{- | `--shards`: one line per matrix row.  Deliberately not a table — this is
   read by people checking a row against ci.yml, and by `grep`. -}
export
renderShards : List Shard -> String
renderShards [] = ""
renderShards (sh::shs) = "\{sh.name}: full_cores=\{boolWord sh.fullCores} wasm_arm=\{boolWord sh.wasmArm} rationale=\{sh.rationale}\n"
  ++ renderShards shs

-- ── CLI ─────────────────────────────────────────────────────────────────────

export
gateHelpText : String
gateHelpText = stringConcat
  [
    "medaka gate — Query the gate registry (test/gates.toml)\n",
    "\n",
    "Usage:\n",
    "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n",
    "  medaka gate list    --shards [--json] [--registry <path>]\n",
    "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n",
    "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n",
    "                      [--registry <path>]\n",
    "  medaka gate verify  [--registry <path>]\n",
    "  medaka gate explain <path> [--prose] [--registry <path>]\n",
    "  medaka gate ci      [--registry <path>] [--workflow <path>]\n",
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
    "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n",
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
    "`gate verify` is the drift gate: text-only, no build. Checks every gate\n",
    "candidate (test/preflight.sh's own candidate universe) is enrolled or\n",
    "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n",
    "targets exist, every entry is reachable by a selector, and no two entries\n",
    "share a `name`. Exits nonzero\n",
    "on any violation.\n",
    "\n",
    "`gate ci` regenerates the marked GENERATED region in\n",
    ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n",
    "the registry's [[shard]] rows and every entry's `shard` field. Run it\n",
    "via `make gen-ci`; it is idempotent, so `git diff --exit-code` after a\n",
    "run is the drift check. The named-gate steps in soundness/wasm are NOT\n",
    "generated — the registry cannot say which job runs which (see the\n",
    "`gate ci` section of compiler/tools/gate_cmd.mdk).\n",
    "\n",
    "`gate explain <path>` is the reverse lookup: which entries select a\n",
    "changed path, and why. Two layers, printed with preflight's own prefixes:\n",
    "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n",
    "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n",
    "`sources` globs and `corpus` directories on GATE lines. A bare token that\n",
    "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n",
    "\n",
    "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n",
    "`NONDOC`, and reads no registry. It exists so that\n",
    "test/diff_compiler_prose_classifier.sh can diff this classifier against\n",
    "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n",
  ]

-- Parsed `gate list` argv.
data ListArgs =
  | ListArgs {
      json : Bool,
      shards : Bool,
      registry : Option String,
      selectors : List String,
    }

parseListArgs : List String -> ListArgs -> Result String ListArgs
parseListArgs [] acc =
  Ok ListArgs { acc | selectors = reverseStrs acc.selectors [] }
parseListArgs ("--json"::rest) acc =
  parseListArgs rest ListArgs { acc | json = True }
parseListArgs ("--shards"::rest) acc =
  parseListArgs rest ListArgs { acc | shards = True }
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
listOutput argv = match parseListArgs argv ListArgs { json = False, shards = False, registry = None, selectors = [] }
  Err m => Err m
  Ok a => match parseSelectors a.selectors []
    Err m => Err "medaka gate list: \{m}"
    Ok sels =>
      let path = registryPath a.registry
      match readFile path
        Err m => Err "medaka gate list: cannot read registry: \{m}"
        Ok src => if a.shards then shardsOutput a.json a.selectors src
        else match parseRegistry src
          Err m => Err "medaka gate list: \{m}"
          Ok gates =>
            selectionOutput a.json a.selectors (selectGates sels gates) path

-- `--shards` lists the MATRIX ROWS, which selectors do not range over — a
-- selector is a per-gate predicate, and silently ignoring one here would let
-- `list --shards area:eval` look like it had filtered something.
shardsOutput : Bool -> List String -> String -> Result String String
shardsOutput isJson tokens src
  | not (isEmptyStrs tokens) = Err "medaka gate list: --shards takes no selectors (got: \{joinSpace tokens})"
  | otherwise = match parseShards src
    Err m => Err "medaka gate list: \{m}"
    Ok shs =>
      if isJson then
        Ok (renderShardsJson shs ++ "\n")
      else
        Ok (renderShards shs)

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

{- | `medaka gate <sub> …`. -}
export
runGateCmd : List String -> <IO> Unit
runGateCmd [] =
  emit (Err
    "usage: medaka gate <list|run|verify|explain|ci> [<selector>...] [--json]")
runGateCmd ("list"::rest) = emit (listOutput rest)
runGateCmd ("run"::rest) = runRunCmdBody rest
runGateCmd ("verify"::rest) = verifyCmdBody rest
runGateCmd ("explain"::rest) = explainCmdBody rest
runGateCmd ("ci"::rest) = ciCmdBody rest
runGateCmd (sub::_) =
  emit (Err
    "medaka gate: unknown subcommand '\{sub}' (expected: list, run, verify, explain, ci)")

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
-- Like run_gates.sh, this ALSO scrapes `test/bin/<name>` out of each selected
-- gate's own script text, unioned with the registry's `oracles` field (S-2).
-- The registry field alone is not enough: it is deliberately FILTERED to
-- names build_oracles.sh's ENTRIES can build (S-2's `oracles = scrape ∩
-- ENTRIES`) — correct for driving builds, but a `test/bin/<name>` the filter
-- dropped (the wasm probes, mostly) is still a real binary a gate's script
-- can open, and staleness is about "is this specific binary current", not
-- "who builds it".  That second question belongs to `verify`'s EXISTENCE
-- check (`knownOracles`/`foreignOracles`, S-4) — which stays filtered on
-- purpose; do not conflate the two.

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

-- The unfiltered scrape, mirroring run_gates.sh's own
-- `grep -ohE 'test/bin/[a-z_0-9]+' "$g" | sed 's|test/bin/||'` over one gate
-- script's text.
binTokenPrefix : String
binTokenPrefix = "test/bin/"

stripBinPrefix : String -> String
stripBinPrefix s =
  if startsWith binTokenPrefix s then
    stringSlice (stringLength binTokenPrefix) (stringLength s) s
  else
    s

scrapedOraclesIn : String -> <IO> List String
scrapedOraclesIn scriptPath = match runCommand "grep" ["-ohE", "test/bin/[a-z_0-9]+", scriptPath]
  Err _ => []
  Ok (_, out, _) => map stripBinPrefix (filterList nonBlankLine (splitNl out))

nonBlankLine : String -> Bool
nonBlankLine s = stringTrim s /= ""

scrapedOracles : String -> List Gate -> <IO> List String
scrapedOracles _ [] = []
scrapedOracles root (g::gs) = scrapedOraclesIn "\{root}/\{g.run}"
  ++ scrapedOracles root gs

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
    let names = sortUniqS (selectedOracles gs ++ scrapedOracles root gs)
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

-- ── `gate verify` ───────────────────────────────────────────────────────────
--
-- The drift gate (#2176 S-4, docs/ops/GATE-REGISTRY-DESIGN.md §3).  TEXT-ONLY,
-- no build — runs everywhere, cheap.  Four checks, each its own violation
-- class:
--
--   1. every gate CANDIDATE — test/preflight.sh's own `_gate_candidates`
--      (tracked-or-untracked `*.sh`, MINUS every name in
--      test/CI-COVERAGE-TOOLS.txt) — is ENROLLED (some entry's `run` equals
--      its path) or excluded there.  No third state.  This mirrors
--      preflight's own two `git ls-files` calls exactly rather than
--      re-deriving the universe — see the packet's own warning: any drift
--      here would make `verify` green over a corpus S-2 already reconciled,
--      proving nothing.
--   2. every entry's `run` target exists on disk.
--   3. every entry's non-empty `oracles` names a real
--      `test/build_oracles.sh --list` entry.
--   4. every entry is reachable by at least one selector.  Under today's
--      schema this is TRIVIALLY true for every well-formed entry (a literal
--      glob always matches itself) — the one shape that can fail is an entry
--      whose `name` itself contains a `:`, which the BARE-sugar CLI form
--      misparses as an unknown `field:` prefix (`parseSelector`) even though
--      the explicit `name:<name>` form still finds it.  Both are checked
--      here.
--   5. every `corpus` entry is a DIRECTORY that exists on disk (S-5).  A
--      corpus value is a literal path, never a glob, so this is a real check
--      and it is the one that catches bulk data rot: a fixture directory
--      renamed out from under the registry silently stops selecting its
--      consumers, which is a QUIETER failure than a red gate.
--
-- `sources` is deliberately NOT checked the same way, and that is not an
-- oversight: a `sources` value is a GLOB (`compiler/*/*.mdk`, `stdlib/*`),
-- every `*`/`?` string is syntactically valid by construction, and a glob that
-- matches nothing TODAY can be exactly right (it names where a file will land).
-- "Exists on disk" is a question `corpus` can answer and `sources` cannot.

nonBlank : String -> Bool
nonBlank s = stringTrim s /= ""

-- The exact two invocations test/preflight.sh's `_gate_candidates` makes,
-- scoped to THIS worktree (never a bare filesystem walk — this box keeps many
-- agent worktrees, and `git ls-files` stays scoped to the working tree it is
-- run in).
--
-- FAILS LOUD, not `[]` — a spawn failure or a nonzero `git` exit (the classic
-- "detected dubious ownership" exit 128 a container/shared runner produces)
-- must not read as "zero candidates," which `verifyClasses`' check 1 cannot
-- tell apart from a genuinely clean tree.  `toolNames`/`knownOracles` below
-- stay `Err _ => []` on purpose — that failure direction is SAFE for them
-- (every ledgered tool/oracle reports as *missing*, which reds loud) — but an
-- empty candidate list can't itself say "verify couldn't check anything," so
-- this one needs an explicit top-level error instead.
gitExitMsg : Int -> String -> String
gitExitMsg code msg =
  if msg == "" then
    "git ls-files exited \{intToString code}"
  else
    "git ls-files exited \{intToString code}: \{msg}"

gitLsFilesSh : String -> List String -> <IO> Result String (List String)
gitLsFilesSh root args = match runCommand "git" (["-C", root] ++ args ++ ["*.sh"])
  Err e => Err "git ls-files failed to run: \{e}"
  Ok (0, out, _) => Ok (filterList nonBlank (splitNl out))
  Ok (code, _, err) => Err (gitExitMsg code (stringTrim err))

gateCandidates : String -> <IO> Result String (List String)
gateCandidates root = match gitLsFilesSh root ["ls-files"]
  Err m => Err m
  Ok tracked => map (untracked => sortUniqS (tracked ++ untracked)) (gitLsFilesSh root ["ls-files", "-o", "--exclude-standard"])

-- test/CI-COVERAGE-TOOLS.txt: one non-comment, non-blank line per excluded
-- tool, keyed by its FIRST whitespace-separated token (repo-relative path,
-- no `.sh`) — the same `awk 'NF { print $1 }'` preflight.sh runs.
liveLine : String -> Bool
liveLine l = nonBlank l && not (startsWith "#" (stringTrim l))

firstToken : String -> String
firstToken l = firstNonBlankTok (splitOnChar ' ' l)

firstNonBlankTok : List String -> String
firstNonBlankTok [] = ""
firstNonBlankTok (x::xs) = if nonBlank x then x else firstNonBlankTok xs

toolNames : String -> <IO> List String
toolNames root = match readFile (joinPath root "test/CI-COVERAGE-TOOLS.txt")
  Err _ => []
  Ok src =>
    filterList nonBlank (map firstToken (filterList liveLine (splitNl src)))

stripSh : String -> String
stripSh p = if endsWith ".sh" p then stringSlice 0 (stringLength p - 3) p else p

allRuns : List Gate -> List String
allRuns [] = []
allRuns (g::gs) = g.run :: allRuns gs

-- Check 1: every candidate is enrolled (its path is some entry's `run`) or
-- excluded (its path minus `.sh` is in test/CI-COVERAGE-TOOLS.txt).
unenrolledViolations : List String -> List String -> List String -> List String
unenrolledViolations _ _ [] = []
unenrolledViolations tools runs (c::cs)
  | contains (stripSh c) tools = unenrolledViolations tools runs cs
  | contains c runs = unenrolledViolations tools runs cs
  | otherwise = "unenrolled: \{c}  (not a `run` in test/gates.toml, not listed in test/CI-COVERAGE-TOOLS.txt)" :: unenrolledViolations tools runs cs

-- Check 2: every entry's `run` target exists on disk (S-1/S-2's decision:
-- `run` is already the resolved relative path — a plain file-exists check,
-- not a re-glob against run_gates.sh's two-glob rule).
runTargetViolations : String -> List Gate -> <IO> List String
runTargetViolations _ [] = []
runTargetViolations root (g::gs) =
  let rest = runTargetViolations root gs
  if fileExists "\{root}/\{g.run}" then
    rest
  else
    "\{g.name}: run target does not exist: \{g.run}"::rest

-- Check 3: every non-empty oracle name is one of build_oracles.sh's own
-- ENTRIES (via its `--list` mode — no clang/libgc needed, builds nothing).
knownOracles : String -> <IO> List String
knownOracles root = match runCommand "sh" ["\{root}/test/build_oracles.sh", "--list"]
  Err _ => []
  Ok (_, out, _) => filterList nonBlank (splitNl out)

-- Two probe names build_oracles.sh deliberately does NOT list in ENTRIES,
-- because a DIFFERENT script builds them (test/wasm/build_wasm_oracle.sh) —
-- build_oracles.sh's own `_foreign` comment names exactly these two ("the
-- emit probes ... are not in ENTRIES at all; they are built by
-- test/wasm/build_wasm_oracle.sh"). Named here rather than re-derived, the
-- same "named exception" shape test/diff_compiler_project_enrolment.sh's
-- UNIVERSAL_GATES uses — treating them as unknown would red `verify` on the
-- clean tree over a probe that is real and does get built, just not by this
-- script.
foreignOracles : List String
foreignOracles = ["wasm_emit_main", "wasm_emit_modules_main"]

oracleNamesMissing : List String -> String -> List String -> List String
oracleNamesMissing _ _ [] = []
oracleNamesMissing known gname (o::os)
  | contains o known || contains o foreignOracles =
    oracleNamesMissing known gname os
  | otherwise = "\{gname}: oracle not known to `test/build_oracles.sh --list` (nor the wasm-foreign set): \{o}" :: oracleNamesMissing known gname os

oracleTargetViolations : List String -> List Gate -> List String
oracleTargetViolations _ [] = []
oracleTargetViolations known (g::gs) = oracleNamesMissing known g.name g.oracles
  ++ oracleTargetViolations known gs

-- Check 4: every entry is reachable by at least one selector.  See the block
-- comment above for why this is near-vacuous under today's schema, and the
-- one shape (a `:` in `name`) that is not.
anyNamed : String -> List Gate -> Bool
anyNamed _ [] = False
anyNamed n (g::gs) = g.name == n || anyNamed n gs

reachabilityFor : List Gate -> Gate -> List String
reachabilityFor all g = match parseSelector g.name
  Err m => [
    "\{g.name}: its own name is not a valid bare selector (\{m}) — reachable only via an explicit `name:\{g.name}`, not the bare CLI form"
  ]
  Ok sel =>
    if anyNamed g.name (selectGates [sel] all) then
      []
    else
      [
        "\{g.name}: `name:\{g.name}` does not select this entry (registry/selector bug)"
      ]

reachabilityViolations : List Gate -> List Gate -> List String
reachabilityViolations _ [] = []
reachabilityViolations all (g::gs) = reachabilityFor all g
  ++ reachabilityViolations all gs

-- Check 5 (S-5): every `corpus` entry is a real DIRECTORY.  `listDir` is the
-- discriminator — `fileExists` is true for a plain file too, and a corpus
-- value that has decayed from a directory into a file is exactly the drift
-- worth naming.
dirExists : String -> <IO> Bool
dirExists p = match listDir p
  Err _ => False
  Ok _ => True

corpusDirsMissing : String -> String -> List String -> <IO> List String
corpusDirsMissing _ _ [] = []
corpusDirsMissing root gname (c::cs) =
  let rest = corpusDirsMissing root gname cs
  if dirExists (joinPath root c) then
    rest
  else
    "\{gname}: corpus directory does not exist: \{c}"::rest

corpusTargetViolations : String -> List Gate -> <IO> List String
corpusTargetViolations _ [] = []
corpusTargetViolations root (g::gs) = corpusDirsMissing root g.name g.corpus
  ++ corpusTargetViolations root gs

-- Check 6 (#2199): entry `name`s are UNIQUE.  Two entries sharing a name were
-- merely redundant while the registry only described gates; with `shard` on
-- the entry they are a GENERATION HAZARD — "which matrix row does `foo` go
-- in" stops having one answer, and the generator would have to pick, silently.
-- Nothing else catches it: `run` targets, oracles and corpora would all still
-- exist, and check 4's reachability is satisfied by EITHER twin.
gateNames : List Gate -> List String
gateNames [] = []
gateNames (g::gs) = g.name :: gateNames gs

countName : String -> List Gate -> Int
countName _ [] = 0
countName n (g::gs) = (if g.name == n then 1 else 0) + countName n gs

dupNameFrom : List Gate -> List String -> List String
dupNameFrom _ [] = []
dupNameFrom gates (n::ns) =
  let k = countName n gates
  let rest = dupNameFrom gates ns
  if k > 1 then
    "\{n}: \{intToString k} entries share this name — a gate's shard row must not be ambiguous"::rest
  else
    rest

duplicateNameViolations : List Gate -> List String
duplicateNameViolations gates = dupNameFrom gates (sortUniqS (gateNames gates))

-- ── assembling and rendering the six classes ────────────────────────────────

verifyClasses : String -> List Gate -> <IO> Result String (List (String, List String))
verifyClasses root gates = match gateCandidates root
  Err m => Err "could not enumerate gate candidates: \{m}"
  Ok cands =>
    let tools = toolNames root
    let runs = allRuns gates
    let known = knownOracles root
    Ok
      [
        ("unenrolled gate scripts", unenrolledViolations tools runs cands),
        ("missing run targets", runTargetViolations root gates),
        ("missing oracle targets", oracleTargetViolations known gates),
        ("missing corpus targets", corpusTargetViolations root gates),
        ("unreachable entries", reachabilityViolations gates gates),
        ("duplicate entry names", duplicateNameViolations gates),
      ]

renderClass : (String, List String) -> String
renderClass (title, []) = "OK    \{title}: 0\n"
renderClass (title, vs) =
  let names = joinNl (indentedNames vs)
  "FAIL  \{title}: \{intToString (listLen vs)}\n\{names}\n"

renderClasses : List (String, List String) -> String
renderClasses [] = ""
renderClasses (c::cs) = renderClass c ++ renderClasses cs

totalViolations : List (String, List String) -> Int
totalViolations [] = 0
totalViolations ((_, vs)::cs) = listLen vs + totalViolations cs

verifyOutput : String -> List Gate -> <IO> Result String String
verifyOutput root gates = match verifyClasses root gates
  Err m => Err "medaka gate verify: \{m}\n"
  Ok classes =>
    let n = totalViolations classes
    let body = renderClasses classes
    if n == 0 then
      Ok (body ++ "medaka gate verify: OK — \{intToString (listLen gates)} entries, 0 violations.\n")
    else
      Err (body ++ "medaka gate verify: FAIL — \{intToString n} violation(s) across \{intToString (listLen gates)} entries.\n")

-- `verify` prints its body even on failure — the message-carrying `Err`
-- string above IS the violation report, not a one-liner, so `emit`'s ordinary
-- "print to stderr and exit 1" path is exactly what we want here too.
data VerifyArgs = VerifyArgs { registry : Option String }

parseVerifyArgs : List String -> VerifyArgs -> Result String VerifyArgs
parseVerifyArgs [] acc = Ok acc
parseVerifyArgs ("--registry"::p::rest) acc =
  parseVerifyArgs rest VerifyArgs { acc | registry = Some p }
parseVerifyArgs ("--registry"::[]) _ =
  Err "medaka gate verify: --registry needs a path"
parseVerifyArgs (a::_) _ = Err "medaka gate verify: unknown flag: \{a}"

verifyCmdBody : List String -> <IO> Unit
verifyCmdBody argv = match parseVerifyArgs argv VerifyArgs { registry = None }
  Err m => emit (Err m)
  Ok a =>
    let path = registryPath a.registry
    match readFile path
      Err m => emit (Err "medaka gate verify: cannot read registry: \{m}")
      Ok src => match parseRegistry src
        Err m => emit (Err "medaka gate verify: \{m}")
        Ok gates =>
          let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
          emit (verifyOutput root gates)

-- ── `gate explain <path>` ────────────────────────────────────────────────────
--
-- The reverse lookup: given a CHANGED PATH, which registry entries select it,
-- and via which field?  Two layers, and they are deliberately SEPARATE code
-- paths rather than two flavours of the same match:
--
--   1. REGISTRY-LEVEL POLICY (design doc §2) — the transfer of
--      test/preflight.sh's `mark_full` and of its UNMAPPED fail-open.  A
--      blast-radius path selects the WHOLE suite whatever any entry says, and
--      a non-prose path no entry claims fails OPEN to the whole suite rather
--      than selecting nothing.  Neither is per-gate data: encoding them as
--      per-entry `sources` globs — giving every one of the entries a
--      `stdlib/*` source so it always matches — would make every entry's data
--      a lie about what that gate actually reads, and would leave nothing able
--      to answer "is this path mapped at all?".  preflight draws the same
--      line: `mark_full` is its own function, not another `add` case arm.
--   2. PER-ENTRY MATCHING against `sources` (globs, matched against the whole
--      path; `*` crosses `/`) and `corpus` (fixture/project DIRECTORIES — a
--      path matches when it IS the dir or lives under it).
--
-- ⚠️ A `sources` glob of exactly `*` is a WHOLE-TREE source (today only
-- diff_compiler_source_bytes, which re-scans every tracked file whatever
-- changed).  It matches every path by construction, so it must never
-- establish that a path is MAPPED — otherwise layer 1's fail-open could never
-- fire again and an unmapped path would silently select one whole-tree gate
-- instead of the suite.  preflight draws exactly this line too: its
-- unconditional `add 'diff_compiler_source_bytes'` sits OUTSIDE the case table
-- whose misses it reports as UNMAPPED.
--
-- Output uses preflight's own machine-readable prefixes (GATE / FULL /
-- UNMAPPED), so the two derivations can be diffed line-for-line.

-- Layer 1a: the blast-radius prefixes.  These are exactly the paths
-- test/preflight.sh answers with `mark_full` (`compiler/support/*`,
-- `compiler/entries/*`, `stdlib/*|runtime/*`), and they are policy, not data.
export
blastRadiusPrefixes : List String
blastRadiusPrefixes =
  ["compiler/support/*", "compiler/entries/*", "stdlib/*", "runtime/*"]

blastHit : List String -> String -> Option String
blastHit [] _ = None
blastHit (p::ps) path = if globMatch p path then Some p else blastHit ps path

{- | Layer 1b: is this path PROSE?  The same allowlist
   `.github/workflows/ci.yml`'s `detect` job applies (its `nondoc` case), kept
   in the same order for the same reason its own comment gives: `test/**` is
   NEVER prose (it holds functional goldens), and `docs/spec/SYNTAX.md` is an
   executable spec.

   > isProsePath "docs/ops/CI-ARCHITECTURE.md"
   True

   > isProsePath "docs/spec/SYNTAX.md"
   False

   > isProsePath "test/gates.toml"
   False

   > isProsePath "compiler/tools/gate_cmd.mdk"
   False -}
export
isProsePath : String -> Bool
isProsePath p
  | startsWith "test/" p = False
  | p == "docs/spec/SYNTAX.md" = False
  | startsWith "docs/" p = True
  | p == "LICENSE" = True
  | startsWith "LICENSE." p = True
  | endsWith ".md" p = True
  | otherwise = False

{- | `medaka gate explain --prose <path>`: layer 1b's verdict ALONE, on one
   line, reading no registry at all.

   This is not a convenience.  `explainOutput` prints the prose note only when
   NO entry claims the path, so a `docs/` path some entry's `sources` happened
   to match would print GATE lines and never reveal its prose verdict — which
   makes the full `explain` output unusable as a classifier probe.  This
   surface is what test/diff_compiler_prose_classifier.sh (#2200) diffs,
   path by path, against the `case` block ci.yml's `detect` job actually runs
   (extracted from ci.yml between its `PROSE-ALLOWLIST:BEGIN`/`:END` markers
   and executed, not re-implemented) — the two hand-written copies of one
   allowlist now have a check tying them together.

   > proseVerdict "docs/ops/CI-ARCHITECTURE.md"
   "PROSE\n"

   > proseVerdict "test/gates.toml"
   "NONDOC\n" -}
export
proseVerdict : String -> String
proseVerdict p = if isProsePath p then "PROSE\n" else "NONDOC\n"

-- Layer 2: per-entry matching.

wholeTreeGlob : String -> Bool
wholeTreeGlob g = g == "*"

sourceMatches : String -> List String -> List String
sourceMatches _ [] = []
sourceMatches path (s::ss)
  | wholeTreeGlob s = sourceMatches path ss
  | globMatch s path = "sources:\{s}" :: sourceMatches path ss
  | otherwise = sourceMatches path ss

{- | A `corpus` entry is a DIRECTORY, not a glob: a changed path is in it when
   the path is that directory or lives under it.

   > underDir "test/llvm_fixtures" "test/llvm_fixtures/a.mdk"
   True

   > underDir "test/llvm_fixtures" "test/llvm_fixtures_typed/a.mdk"
   False -}
export
underDir : String -> String -> Bool
underDir d path = path == d || startsWith "\{d}/" path

corpusMatches : String -> List String -> List String
corpusMatches _ [] = []
corpusMatches path (c::cs)
  | underDir c path = "corpus:\{c}" :: corpusMatches path cs
  | otherwise = corpusMatches path cs

targetedReasons : String -> Gate -> List String
targetedReasons path g = sourceMatches path g.sources
  ++ corpusMatches path g.corpus

explainPathHits : String -> List Gate -> List (Gate, List String)
explainPathHits _ [] = []
explainPathHits path (g::gs) =
  let rs = targetedReasons path g
  let rest = explainPathHits path gs
  if isEmptyStrs rs then rest else (g, rs)::rest

hasWholeTree : List String -> Bool
hasWholeTree [] = False
hasWholeTree (s::ss) = wholeTreeGlob s || hasWholeTree ss

wholeTreeGates : List Gate -> List Gate
wholeTreeGates [] = []
wholeTreeGates (g::gs)
  | hasWholeTree g.sources = g :: wholeTreeGates gs
  | otherwise = wholeTreeGates gs

-- ── the selector-token half (S-4): a bare token that IS a field value ───────

fieldHit : String -> Bool -> List String
fieldHit _ False = []
fieldHit field True = [field]

matchedFields : String -> Gate -> List String
matchedFields tok g = fieldHit "run" (tok == g.run)
  ++ fieldHit "name" (tok == g.name)
  ++ fieldHit "area" (tok == g.area)
  ++ fieldHit "project" (tok == g.project)
  ++ fieldHit "tier" (tok == g.tier)

explainMatches : String -> List Gate -> List (Gate, List String)
explainMatches _ [] = []
explainMatches tok (g::gs) =
  let fs = matchedFields tok g
  let rest = explainMatches tok gs
  if isEmptyStrs fs then rest else (g, fs)::rest

isEmptyHits : List (Gate, List String) -> Bool
isEmptyHits [] = True
isEmptyHits _ = False

renderGateLines : List (Gate, List String) -> String
renderGateLines [] = ""
renderGateLines ((g, rs)::hs) = "  GATE      \{g.name}  (\{joinWith ", " rs})\n"
  ++ renderGateLines hs

renderWholeTree : List Gate -> String
renderWholeTree [] = ""
renderWholeTree (g::gs) = "  GATE      \{g.name}  (sources:*, whole-tree)\n"
  ++ renderWholeTree gs

renderTokenLines : List (Gate, List String) -> String
renderTokenLines [] = ""
renderTokenLines ((g, fs)::hs) = "  TOKEN     \{g.name}  (selector field: \{joinWith ", " fs})\n"
  ++ renderTokenLines hs

tokenSection : String -> List Gate -> String
tokenSection tok gates =
  let hits = explainMatches tok gates
  if isEmptyHits hits then "" else renderTokenLines hits

blastNote : String
blastNote = "  (registry-level policy, not per-entry data: a blast-radius path runs the\n"
  ++ "   WHOLE suite whatever any entry's sources say — design doc §2.)\n"

failOpenNote : String
failOpenNote = "  (no entry's sources/corpus claims this path and it is not prose, so the\n"
  ++ "   selection FAILS OPEN to the whole suite — never a silent empty set.)\n"

proseNote : String
proseNote = "  (prose: no entry claims it and it cannot widen the suite — ci.yml's own\n"
  ++ "   docs allowlist, `detect` job.)\n"

{- | `medaka gate explain <path>`: the policy verdict, then the entries that
   select the path and why. -}
export
explainOutput : String -> List Gate -> String
explainOutput path gates =
  let wt = renderWholeTree (wholeTreeGates gates)
  let tok = tokenSection path gates
  let hits = explainPathHits path gates
  match blastHit blastRadiusPrefixes path
    Some p => "  FULL      blast-radius:\{p}\n" ++ blastNote ++ wt ++ tok
    None =>
      if isEmptyHits hits then
        (if isProsePath path then "  UNMAPPED  \{path}\n" ++ proseNote else "  UNMAPPED  \{path}\n  FULL      unmatched-non-prose:\{path}\n" ++ failOpenNote) ++ wt ++ tok
      else
        renderGateLines hits ++ wt ++ tok

data ExplainArgs =
  | ExplainArgs { registry : Option String, path : Option String, prose : Bool }

parseExplainArgs : List String -> ExplainArgs -> Result String ExplainArgs
parseExplainArgs [] acc = Ok acc
parseExplainArgs ("--registry"::p::rest) acc =
  parseExplainArgs rest ExplainArgs { acc | registry = Some p }
parseExplainArgs ("--registry"::[]) _ =
  Err "medaka gate explain: --registry needs a path"
parseExplainArgs ("--prose"::rest) acc =
  parseExplainArgs rest ExplainArgs { acc | prose = True }
parseExplainArgs (a::rest) acc
  | stringLength a > 0 && stringSlice 0 1 a == "-" =
    Err "medaka gate explain: unknown flag: \{a}"
  | otherwise = match acc.path
    Some _ => Err "medaka gate explain: expected exactly one <path> argument"
    None => parseExplainArgs rest ExplainArgs { acc | path = Some a }

explainCmdBody : List String -> <IO> Unit
explainCmdBody argv = match parseExplainArgs argv ExplainArgs { registry = None, path = None, prose = False }
  Err m => emit (Err m)
  Ok a => match a.path
    None => emit (Err "usage: medaka gate explain <path> [--prose] [--registry <path>]")
    Some tok => if a.prose then putStr (proseVerdict tok)
    else
      let path = registryPath a.registry
      match readFile path
        Err m => emit (Err "medaka gate explain: cannot read registry: \{m}")
        Ok src => match parseRegistry src
          Err m => emit (Err "medaka gate explain: \{m}")
          Ok gates => putStr (explainOutput tok gates)

-- ── `gate ci` — regenerate ci.yml's generated regions ───────────────────────
--
-- `medaka gate ci` (via `make gen-ci`) rewrites the ONE marked region in
-- `.github/workflows/ci.yml`: the `gates` job's `matrix.include:` block.  Each
-- of the eight rows is a pure function of the registry — the `[[shard]]` row
-- (its runner options and the path to its placement prose) plus every
-- `[[gate]]` whose `shard` names it — so the matrix can no longer disagree
-- with the data `medaka gate list` answers from.
--
-- Marker convention, following `docs/README.md`'s (`test/gen_docs_index.sh`):
-- a GENERATED region is delimited by two YAML comment lines at the region's
-- own indent, the file is otherwise hand-written, and regeneration is
-- idempotent so `make gen-ci && git diff --exit-code` is the drift check.
--
-- ⚠️ PATTERN BYTE-ORDER IS NOT PRESERVED, ON PURPOSE.  ci.yml's rows were
-- hand-written as GLOBS (`'diff_compiler_lex*'`); the registry stores one
-- `shard` per gate and no globs, so the only thing derivable from it is the
-- resolved gate-NAME list.  The generated `pattern:` therefore names every
-- gate in the row literally, in registry declaration order.  What is preserved
-- is what run_gates.sh actually consumes: the SET of gates each row resolves
-- to (contract §7.2(b)).  Quoting is reproduced exactly and is load-bearing on
-- both layers — outer double quotes make one YAML scalar, inner single quotes
-- survive into `sh` unexpanded (run_gates.sh runs under dash).
--
-- ⚠️ THE NAMED-GATE STEPS ARE NOT GENERATED, AND THAT IS A MEASUREMENT, NOT AN
-- OMISSION.  `soundness`/`compiler-soundness`/`wasm` invoke gates by literal
-- name rather than through a shard pattern, and the registry cannot say which
-- job runs which: `shard = "other-job"` is one sentinel covering seven
-- different jobs (S-1's report §7).  The counterexample is exact —
-- `check_fingerprint_parity` and `check_keyword_sync` carry IDENTICAL values
-- in every scheduling field (`area = "types"`, `shard = "other-job"`,
-- `project = "compiler"`, `tier = "merge"`, `cost = "cheap"`,
-- `kind = "exec"`), yet the first is a step of `compiler-soundness` under that
-- job's `needs.detect` guard and the second is a step of `soundness`, which
-- ci.yml documents as DELIBERATELY UNGUARDED ("guarding a doc gate on
-- docs_only would skip it on precisely the PRs it exists to police").
-- Generating those steps would mean hard-coding a job -> gate-name table HERE,
-- which relocates the authority from ci.yml into this file without making the
-- registry the source of truth — strictly worse than the hand-written steps it
-- would replace.  Their coverage is a reachability question
-- (`diff_compiler_ci_shard_coverage.sh` already counts a literal name in a
-- step as covering that gate), not a placement one, and it belongs to S-4.
--
-- Byte-determinism: every list below is a fold over FILE ORDER (the registry's
-- own `[[shard]]` and `[[gate]]` order) — no sort, no locale-sensitive
-- comparison, nothing read from the environment.  `make gen-ci` still exports
-- `LC_ALL=C` as `test/gen_docs_index.sh` does, so the two generators keep one
-- story about reproducibility even though this one has no `sort` to pin.

-- The workflow file, and the region markers inside it.  Both markers are
-- matched as WHOLE LINES at the matrix's own indent, so a mention of either
-- string in prose elsewhere in the file cannot be mistaken for the region.
ciWorkflowRel : String
ciWorkflowRel = ".github/workflows/ci.yml"

ciMatrixBegin : String
ciMatrixBegin = "          # GENERATED:BEGIN gates-matrix — `make gen-ci` (medaka gate ci) from test/gates.toml. DO NOT EDIT BY HAND."

ciMatrixEnd : String
ciMatrixEnd = "          # GENERATED:END gates-matrix"

-- One line of a row's placement prose, as a YAML comment at the field indent.
-- A blank prose line becomes a bare `#`, never `# ` — a trailing space is
-- invisible in review and would make the output differ from a hand-edit.
ciProseLine : String -> String
ciProseLine "" = "            #"
ciProseLine l = "            # \{l}"

-- Drop the single empty segment `splitNl` leaves for a file's trailing
-- newline.  A prose file with a genuine blank LAST line would lose it; that is
-- the same normalization every other consumer of these files applies, and a
-- trailing blank comment line carries nothing.
dropTrailBlank : List String -> List String
dropTrailBlank [] = []
dropTrailBlank (x::[])
  | x == "" = []
  | otherwise = [x]
dropTrailBlank (x::xs) = x :: dropTrailBlank xs

-- `'a' 'b' 'c'` — the inner single-quoted token list of a row's pattern.
ciQuotedNames : List Gate -> String
ciQuotedNames [] = ""
ciQuotedNames (g::[]) = "'\{g.name}'"
ciQuotedNames (g::gs) = "'\{g.name}' \{ciQuotedNames gs}"

-- The gates of one row, in registry order.
ciShardGates : String -> List Gate -> List Gate
ciShardGates nm gs = filterList (g => g.shard == nm) gs

-- A `"1"` matrix key is emitted ONLY when the option is on — ci.yml omits the
-- key entirely when off, and that asymmetry is the file's convention, not the
-- registry's (`shardBool` insists the boolean is present in the registry for
-- exactly this reason).
ciOptLine : String -> Bool -> List String
ciOptLine _ False = []
ciOptLine key True = ["            \{key}: \"1\""]

ciRowLines : List Gate -> List String -> Shard -> List String
ciRowLines rowGates prose sh = ["          - name: \{sh.name}"]
  ++ map ciProseLine prose
  ++ ["            pattern: \"\{ciQuotedNames rowGates}\""]
  ++ ciOptLine "full_cores" sh.fullCores
  ++ ciOptLine "wasm_arm" sh.wasmArm

-- Build one row, reading its prose file.  A row with NO gates is a hard error:
-- ci.yml's own `plan` step fails such a shard with `::error::pattern matched NO
-- gates`, and emitting the empty pattern that produces it would be generating
-- a known-broken file.
ciOneRow : String -> List Gate -> Shard -> <IO> Result String (List String)
ciOneRow root gates sh = match ciShardGates sh.name gates
  [] => Err "medaka gate ci: shard '\{sh.name}' has no gates in the registry — a row with an empty pattern fails its own shard in CI"
  rowGates => match readFile (joinPath root sh.rationale)
    Err m => Err "medaka gate ci: shard '\{sh.name}': cannot read rationale \{sh.rationale}: \{m}"
    Ok src => Ok (ciRowLines rowGates (dropTrailBlank (splitNl src)) sh)

ciRowsLoop : String -> List Gate -> List Shard -> List String -> <IO> Result String (List String)
ciRowsLoop _ _ [] acc = Ok (reverseL acc)
ciRowsLoop root gates (sh::shs) acc = match ciOneRow root gates sh
  Err m => Err m
  Ok ls => ciRowsLoop root gates shs (reverseL ls ++ acc)

-- Is every gate's `shard` either a declared row or the `other-job` sentinel?
-- A typo'd shard name would otherwise drop that gate from the matrix SILENTLY
-- — the gate stays in the registry, answers `gate list`, and runs nowhere.
ciKnownShard : List Shard -> String -> Bool
ciKnownShard _ "other-job" = True
ciKnownShard [] _ = False
ciKnownShard (sh::shs) nm = sh.name == nm || ciKnownShard shs nm

ciUnknownShards : List Shard -> List Gate -> List String
ciUnknownShards _ [] = []
ciUnknownShards shs (g::gs)
  | ciKnownShard shs g.shard = ciUnknownShards shs gs
  | otherwise = "\{g.name} (shard '\{g.shard}')" :: ciUnknownShards shs gs

-- ── Splicing the region ─────────────────────────────────────────────────────

ciCountLine : String -> List String -> Int
ciCountLine _ [] = 0
ciCountLine want (l::ls)
  | l == want = 1 + ciCountLine want ls
  | otherwise = ciCountLine want ls

ciIndexOf : String -> List String -> Int -> Int
ciIndexOf _ [] _ = -1
ciIndexOf want (l::ls) i
  | l == want = i
  | otherwise = ciIndexOf want ls (i + 1)

-- Copy from the END marker onward, verbatim.
ciAfterEnd : List String -> List String
ciAfterEnd [] = []
ciAfterEnd (l::ls)
  | l == ciMatrixEnd = l::ls
  | otherwise = ciAfterEnd ls

ciSpliceGo : List String -> List String -> List String
ciSpliceGo _ [] = []
ciSpliceGo gen (l::ls)
  | l == ciMatrixBegin = l :: gen ++ ciAfterEnd ls
  | otherwise = l :: ciSpliceGo gen ls

-- The markers must appear EXACTLY once each, in order.  Anything else is a
-- malformed file, and splicing it would quietly drop or duplicate the region.
ciSplice : List String -> List String -> Result String (List String)
ciSplice gen src
  | ciCountLine ciMatrixBegin src /= 1 = Err "medaka gate ci: \{ciWorkflowRel} must contain exactly one BEGIN marker line (found \{intToString (ciCountLine ciMatrixBegin src)}):\n\{ciMatrixBegin}"
  | ciCountLine ciMatrixEnd src /= 1 = Err "medaka gate ci: \{ciWorkflowRel} must contain exactly one END marker line (found \{intToString (ciCountLine ciMatrixEnd src)}):\n\{ciMatrixEnd}"
  | ciIndexOf ciMatrixEnd src 0 < ciIndexOf ciMatrixBegin src 0 = Err "medaka gate ci: \{ciWorkflowRel}: the END marker precedes the BEGIN marker"
  | otherwise = Ok (ciSpliceGo gen src)

-- ── The command ─────────────────────────────────────────────────────────────

data CiArgs = CiArgs { registry : Option String, workflow : Option String }

parseCiArgs : List String -> CiArgs -> Result String CiArgs
parseCiArgs [] acc = Ok acc
parseCiArgs ("--registry"::p::rest) acc =
  parseCiArgs rest CiArgs { acc | registry = Some p }
parseCiArgs ("--registry"::[]) _ = Err "medaka gate ci: --registry needs a path"
parseCiArgs ("--workflow"::p::rest) acc =
  parseCiArgs rest CiArgs { acc | workflow = Some p }
parseCiArgs ("--workflow"::[]) _ = Err "medaka gate ci: --workflow needs a path"
parseCiArgs (a::_) _ = Err "medaka gate ci: unexpected argument: \{a}"

-- `<MEDAKA_ROOT>/.github/workflows/ci.yml` unless --workflow overrides it —
-- the same exe-relative resolution `registryPath` uses, for the same reason.
ciWorkflowPath : Option String -> String -> String
ciWorkflowPath (Some p) _ = p
ciWorkflowPath None root = joinPath root ciWorkflowRel

-- Everything that can go wrong before a byte is written, as one `Result`, so
-- the command keeps `emit`'s single exit site.
ciNewText : String -> String -> String -> String -> <IO> Result String String
ciNewText root regPath regSrc wfSrc = match parseRegistry regSrc
  Err m => Err "medaka gate ci: \{m}"
  Ok gates => match parseShards regSrc
    Err m => Err "medaka gate ci: \{m}"
    Ok shs => match ciUnknownShards shs gates
      [] => match ciRowsLoop root gates shs []
        Err m => Err m
        Ok gen => map joinNl (ciSplice gen (splitNl wfSrc))
      bad => Err "medaka gate ci: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace bad}"

-- Write only on a real change: an unconditional write would touch the file's
-- mtime on every no-op run, and `make gen-ci` is meant to be free to re-run.
ciWrite : String -> String -> String -> <IO> Unit
ciWrite wfPath wfSrc out
  | out == wfSrc = putStr "medaka gate ci: \{wfPath} already up to date\n"
  | otherwise = match writeFile wfPath out
    Err m => emit (Err "medaka gate ci: cannot write \{wfPath}: \{m}")
    Ok _ => putStr "medaka gate ci: regenerated the gates matrix in \{wfPath}\n"

ciCmdBody : List String -> <IO> Unit
ciCmdBody argv = match parseCiArgs argv CiArgs { registry = None, workflow = None }
  Err m => emit (Err m)
  Ok a =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let regPath = registryPath a.registry
    let wfPath = ciWorkflowPath a.workflow root
    match readFile regPath
      Err m => emit (Err "medaka gate ci: cannot read registry: \{m}")
      Ok regSrc => match readFile wfPath
        Err m => emit (Err "medaka gate ci: cannot read \{wfPath}: \{m}")
        Ok wfSrc => match ciNewText root regPath regSrc wfSrc
          Err m => emit (Err m)
          Ok out => ciWrite wfPath wfSrc out

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
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "getBool" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DData Public "Shard" () ((variant "Shard" (ConNamed (field "name" (TyCon "String")) (field "fullCores" (TyCon "Bool")) (field "wasmArm" (TyCon "Bool")) (field "rationale" (TyCon "String"))))) ())
(DTypeSig false "shardStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardBool" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "shardBool" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Ok") (EVar "b"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required boolean field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readShard" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShard" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "shard"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "full_cores"))) (EVar "e"))) (ELam ((PVar "fullCores")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "wasm_arm"))) (EVar "e"))) (ELam ((PVar "wasmArm")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "rationale"))) (EVar "e"))) (ELam ((PVar "rationale")) (EApp (EVar "Ok") (ERecordCreate "Shard" ((fa "name" (EVar "name")) (fa "fullCores" (EVar "fullCores")) (fa "wasmArm" (EVar "wasmArm")) (fa "rationale" (EVar "rationale"))))))))))))))))
(DTypeSig false "readShardsFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Shard"))))))))
(DFunDef false "readShardsFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseShards") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readShard") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "sh")) () (EApp (EApp (EApp (EApp (EVar "readShardsFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "sh") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Shard")))))
(DFunDef false "reverseShards" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseShards" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseShards") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig true "parseShards" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Shard")))))
(DFunDef false "parseShards" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "shard"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[shard]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readShardsFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
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
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig false "shardJson" (TyFun (TyCon "Shard") (TyCon "Json")))
(DFunDef false "shardJson" ((PVar "sh")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "name"))) (ETuple (ELit (LString "full_cores")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "fullCores"))) (ETuple (ELit (LString "wasm_arm")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "wasmArm"))) (ETuple (ELit (LString "rationale")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "rationale"))))))
(DTypeSig true "renderShardsJson" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShardsJson" ((PVar "shs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "shardJson")) (EVar "shs")))))
(DTypeSig false "boolWord" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolWord" ((PVar "b")) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig true "renderShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShards" ((PList)) (ELit (LString "")))
(DFunDef false "renderShards" ((PCons (PVar "sh") (PVar "shs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString ": full_cores="))) (EApp (EVar "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "fullCores")))) (ELit (LString " wasm_arm="))) (EApp (EVar "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "wasmArm")))) (ELit (LString " rationale="))) (EApp (EVar "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString "\n"))) (EApp (EVar "renderShards") (EVar "shs"))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate ci      [--registry <path>] [--workflow <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, and no two entries\n")) (ELit (LString "share a `name`. Exits nonzero\n")) (ELit (LString "on any violation.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`; it is idempotent, so `git diff --exit-code` after a\n")) (ELit (LString "run is the drift check. The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "shards" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--shards")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "shards" (EVar "True"))))))
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
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "shards" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EIf (EFieldAccess (EVar "a") "shards") (EApp (EApp (EApp (EVar "shardsOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path"))))))))))))))
(DTypeSig false "shardsOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardsOutput" ((PVar "isJson") (PVar "tokens") (PVar "src")) (EIf (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EVar "tokens"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: --shards takes no selectors (got: ")) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString ")")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "parseShards") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderShardsJson") (EVar "shs")) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderShards") (EVar "shs")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run|verify|explain|ci> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EVar "verifyCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) (PVar "rest"))) (EApp (EVar "explainCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "ci")) (PVar "rest"))) (EApp (EVar "ciCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: list, run, verify, explain, ci)"))))))
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
(DTypeSig false "binTokenPrefix" (TyCon "String"))
(DFunDef false "binTokenPrefix" () (ELit (LString "test/bin/")))
(DTypeSig false "stripBinPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripBinPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "binTokenPrefix")) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "binTokenPrefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig false "scrapedOraclesIn" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "scrapedOraclesIn" ((PVar "scriptPath")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "grep"))) (EListLit (ELit (LString "-ohE")) (ELit (LString "test/bin/[a-z_0-9]+")) (EVar "scriptPath"))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EApp (EVar "map") (EVar "stripBinPrefix")) (EApp (EApp (EVar "filterList") (EVar "nonBlankLine")) (EApp (EVar "splitNl") (EVar "out")))))))
(DTypeSig false "nonBlankLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonBlankLine" ((PVar "s")) (EBinOp "/=" (EApp (EVar "stringTrim") (EVar "s")) (ELit (LString ""))))
(DTypeSig false "scrapedOracles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "scrapedOracles" (PWild (PList)) (EListLit))
(DFunDef false "scrapedOracles" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EVar "scrapedOraclesIn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EApp (EApp (EVar "scrapedOracles") (EVar "root")) (EVar "gs"))))
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
(DFunDef false "staleRefusal" ((PCon "False") (PVar "root") (PVar "gs")) (EIf (EBinOp "||" (EApp (EVar "envSet") (ELit (LString "CI"))) (EApp (EVar "envSet") (ELit (LString "NO_STALE_CHECK")))) (EVar "None") (EBlock (DoLet false false (PVar "names") (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EVar "selectedOracles") (EVar "gs")) (EApp (EApp (EVar "scrapedOracles") (EVar "root")) (EVar "gs"))))) (DoLet false false (PVar "newest") (EApp (EVar "newestSourceMtime") (EVar "root"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "names")) (arm (PList) () (EVar "None")) (arm (PVar "stale") () (EApp (EVar "Some") (EApp (EVar "staleBanner") (EVar "stale")))))))))
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
(DTypeSig false "nonBlank" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonBlank" ((PVar "s")) (EBinOp "/=" (EApp (EVar "stringTrim") (EVar "s")) (ELit (LString ""))))
(DTypeSig false "gitExitMsg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "gitExitMsg" ((PVar "code") (PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files exited ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files exited ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "")))))
(DTypeSig false "gitLsFilesSh" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "gitLsFilesSh" ((PVar "root") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "-C")) (EVar "root")) (EVar "args")) (EListLit (ELit (LString "*.sh"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files failed to run: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out"))))) (arm (PCon "Ok" (PTuple (PVar "code") PWild (PVar "err"))) () (EApp (EVar "Err") (EApp (EApp (EVar "gitExitMsg") (EVar "code")) (EApp (EVar "stringTrim") (EVar "err")))))))
(DTypeSig false "gateCandidates" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateCandidates" ((PVar "root")) (EMatch (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "tracked")) () (EApp (EApp (EVar "map") (ELam ((PVar "untracked")) (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "tracked") (EVar "untracked"))))) (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")) (ELit (LString "-o")) (ELit (LString "--exclude-standard"))))))))
(DTypeSig false "liveLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "liveLine" ((PVar "l")) (EBinOp "&&" (EApp (EVar "nonBlank") (EVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "#"))) (EApp (EVar "stringTrim") (EVar "l"))))))
(DTypeSig false "firstToken" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstToken" ((PVar "l")) (EApp (EVar "firstNonBlankTok") (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "l"))))
(DTypeSig false "firstNonBlankTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonBlankTok" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonBlankTok" ((PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "nonBlank") (EVar "x")) (EVar "x") (EApp (EVar "firstNonBlankTok") (EVar "xs"))))
(DTypeSig false "toolNames" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "toolNames" ((PVar "root")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test/CI-COVERAGE-TOOLS.txt")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EApp (EVar "map") (EVar "firstToken")) (EApp (EApp (EVar "filterList") (EVar "liveLine")) (EApp (EVar "splitNl") (EVar "src"))))))))
(DTypeSig false "stripSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSh" ((PVar "p")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".sh"))) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "p")) (ELit (LInt 3)))) (EVar "p")) (EVar "p")))
(DTypeSig false "allRuns" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allRuns" ((PList)) (EListLit))
(DFunDef false "allRuns" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EFieldAccess (EVar "g") "run") (EApp (EVar "allRuns") (EVar "gs"))))
(DTypeSig false "unenrolledViolations" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unenrolledViolations" (PWild PWild (PList)) (EListLit))
(DFunDef false "unenrolledViolations" ((PVar "tools") (PVar "runs") (PCons (PVar "c") (PVar "cs"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "stripSh") (EVar "c"))) (EVar "tools")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs")) (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "runs")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "unenrolled: ")) (EApp (EVar "display") (EVar "c"))) (ELit (LString "  (not a `run` in test/gates.toml, not listed in test/CI-COVERAGE-TOOLS.txt)"))) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runTargetViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "runTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "runTargetViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "fileExists") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EVar "rest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": run target does not exist: "))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString ""))) (EVar "rest"))))))
(DTypeSig false "knownOracles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "knownOracles" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/test/build_oracles.sh"))) (ELit (LString "--list")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out"))))))
(DTypeSig false "foreignOracles" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "foreignOracles" () (EListLit (ELit (LString "wasm_emit_main")) (ELit (LString "wasm_emit_modules_main"))))
(DTypeSig false "oracleNamesMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oracleNamesMissing" (PWild PWild (PList)) (EListLit))
(DFunDef false "oracleNamesMissing" ((PVar "known") (PVar "gname") (PCons (PVar "o") (PVar "os"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EVar "known")) (EApp (EApp (EVar "contains") (EVar "o")) (EVar "foreignOracles"))) (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EVar "gname")) (EVar "os")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gname"))) (ELit (LString ": oracle not known to `test/build_oracles.sh --list` (nor the wasm-foreign set): "))) (EApp (EVar "display") (EVar "o"))) (ELit (LString ""))) (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EVar "gname")) (EVar "os"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "oracleTargetViolations" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oracleTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "oracleTargetViolations" ((PVar "known") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "oracles")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gs"))))
(DTypeSig false "anyNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "Bool"))))
(DFunDef false "anyNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "anyNamed" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EApp (EVar "anyNamed") (EVar "n")) (EVar "gs"))))
(DTypeSig false "reachabilityFor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachabilityFor" ((PVar "all") (PVar "g")) (EMatch (EApp (EVar "parseSelector") (EFieldAccess (EVar "g") "name")) (arm (PCon "Err" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": its own name is not a valid bare selector ("))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ") — reachable only via an explicit `name:"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "`, not the bare CLI form"))))) (arm (PCon "Ok" (PVar "sel")) () (EIf (EApp (EApp (EVar "anyNamed") (EFieldAccess (EVar "g") "name")) (EApp (EApp (EVar "selectGates") (EListLit (EVar "sel"))) (EVar "all"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": `name:"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "` does not select this entry (registry/selector bug)"))))))))
(DTypeSig false "reachabilityViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachabilityViolations" (PWild (PList)) (EListLit))
(DFunDef false "reachabilityViolations" ((PVar "all") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "reachabilityFor") (EVar "all")) (EVar "g")) (EApp (EApp (EVar "reachabilityViolations") (EVar "all")) (EVar "gs"))))
(DTypeSig false "dirExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "dirExists" ((PVar "p")) (EMatch (EApp (EVar "listDir") (EVar "p")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EVar "True"))))
(DTypeSig false "corpusDirsMissing" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "corpusDirsMissing" (PWild PWild (PList)) (EListLit))
(DFunDef false "corpusDirsMissing" ((PVar "root") (PVar "gname") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "corpusDirsMissing") (EVar "root")) (EVar "gname")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "dirExists") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "c"))) (EVar "rest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gname"))) (ELit (LString ": corpus directory does not exist: "))) (EApp (EVar "display") (EVar "c"))) (ELit (LString ""))) (EVar "rest"))))))
(DTypeSig false "corpusTargetViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "corpusTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "corpusTargetViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "corpusDirsMissing") (EVar "root")) (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "corpus")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gs"))))
(DTypeSig false "gateNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gateNames" ((PList)) (EListLit))
(DFunDef false "gateNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EVar "gateNames") (EVar "gs"))))
(DTypeSig false "countName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "Int"))))
(DFunDef false "countName" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countName" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EBinOp "+" (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "countName") (EVar "n")) (EVar "gs"))))
(DTypeSig false "dupNameFrom" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupNameFrom" (PWild (PList)) (EListLit))
(DFunDef false "dupNameFrom" ((PVar "gates") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "countName") (EVar "n")) (EVar "gates"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "dupNameFrom") (EVar "gates")) (EVar "ns"))) (DoExpr (EIf (EBinOp ">" (EVar "k") (ELit (LInt 1))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " entries share this name — a gate's shard row must not be ambiguous"))) (EVar "rest")) (EVar "rest")))))
(DTypeSig false "duplicateNameViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "duplicateNameViolations" ((PVar "gates")) (EApp (EApp (EVar "dupNameFrom") (EVar "gates")) (EApp (EVar "sortUniqS") (EApp (EVar "gateNames") (EVar "gates")))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))))))))))
(DTypeSig false "renderClass" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "OK    ")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": 0\n"))))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PVar "vs"))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "vs")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "names"))) (ELit (LString "\n"))))))
(DTypeSig false "renderClasses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderClasses" ((PList)) (ELit (LString "")))
(DFunDef false "renderClasses" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "++" (EApp (EVar "renderClass") (EVar "c")) (EApp (EVar "renderClasses") (EVar "cs"))))
(DTypeSig false "totalViolations" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "totalViolations" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalViolations" ((PCons (PTuple PWild (PVar "vs")) (PVar "cs"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "vs")) (EApp (EVar "totalViolations") (EVar "cs"))))
(DTypeSig false "verifyOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "verifyOutput" ((PVar "root") (PVar "gates")) (EMatch (EApp (EApp (EVar "verifyClasses") (EVar "root")) (EVar "gates")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "classes")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "totalViolations") (EVar "classes"))) (DoLet false false (PVar "body") (EApp (EVar "renderClasses") (EVar "classes"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: OK — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries, 0 violations.\n"))))) (EApp (EVar "Err") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: FAIL — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " violation(s) across "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries.\n")))))))))))
(DData Private "VerifyArgs" () ((variant "VerifyArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "parseVerifyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "VerifyArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "VerifyArgs")))))
(DFunDef false "parseVerifyArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseVerifyArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseVerifyArgs") (EVar "rest")) (EVariantUpdate "VerifyArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseVerifyArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate verify: --registry needs a path"))))
(DFunDef false "parseVerifyArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: unknown flag: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "verifyCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseVerifyArgs") (EVar "argv")) (ERecordCreate "VerifyArgs" ((fa "registry" (EVar "None"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EVar "emit") (EApp (EApp (EVar "verifyOutput") (EVar "root")) (EVar "gates"))))))))))))))
(DTypeSig true "blastRadiusPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "blastRadiusPrefixes" () (EListLit (ELit (LString "compiler/support/*")) (ELit (LString "compiler/entries/*")) (ELit (LString "stdlib/*")) (ELit (LString "runtime/*"))))
(DTypeSig false "blastHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "blastHit" ((PList) PWild) (EVar "None"))
(DFunDef false "blastHit" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "path")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "blastHit") (EVar "ps")) (EVar "path"))))
(DTypeSig true "isProsePath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isProsePath" ((PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test/"))) (EVar "p")) (EVar "False") (EIf (EBinOp "==" (EVar "p") (ELit (LString "docs/spec/SYNTAX.md"))) (EVar "False") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "docs/"))) (EVar "p")) (EVar "True") (EIf (EBinOp "==" (EVar "p") (ELit (LString "LICENSE"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "LICENSE."))) (EVar "p")) (EVar "True") (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p")) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "proseVerdict" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "proseVerdict" ((PVar "p")) (EIf (EApp (EVar "isProsePath") (EVar "p")) (ELit (LString "PROSE\n")) (ELit (LString "NONDOC\n"))))
(DTypeSig false "wholeTreeGlob" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "wholeTreeGlob" ((PVar "g")) (EBinOp "==" (EVar "g") (ELit (LString "*"))))
(DTypeSig false "sourceMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sourceMatches" (PWild (PList)) (EListLit))
(DFunDef false "sourceMatches" ((PVar "path") (PCons (PVar "s") (PVar "ss"))) (EIf (EApp (EVar "wholeTreeGlob") (EVar "s")) (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss")) (EIf (EApp (EApp (EVar "globMatch") (EVar "s")) (EVar "path")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "sources:")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ""))) (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "underDir" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "underDir" ((PVar "d") (PVar "path")) (EBinOp "||" (EBinOp "==" (EVar "path") (EVar "d")) (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "d"))) (ELit (LString "/")))) (EVar "path"))))
(DTypeSig false "corpusMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "corpusMatches" (PWild (PList)) (EListLit))
(DFunDef false "corpusMatches" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EApp (EApp (EVar "underDir") (EVar "c")) (EVar "path")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "corpus:")) (EApp (EVar "display") (EVar "c"))) (ELit (LString ""))) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "targetedReasons" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "targetedReasons" ((PVar "path") (PVar "g")) (EBinOp "++" (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EFieldAccess (EVar "g") "sources")) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EFieldAccess (EVar "g") "corpus"))))
(DTypeSig false "explainPathHits" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "explainPathHits" (PWild (PList)) (EListLit))
(DFunDef false "explainPathHits" ((PVar "path") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EVar "targetedReasons") (EVar "path")) (EVar "g"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "explainPathHits") (EVar "path")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "rs")) (EVar "rest") (EBinOp "::" (ETuple (EVar "g") (EVar "rs")) (EVar "rest"))))))
(DTypeSig false "hasWholeTree" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasWholeTree" ((PList)) (EVar "False"))
(DFunDef false "hasWholeTree" ((PCons (PVar "s") (PVar "ss"))) (EBinOp "||" (EApp (EVar "wholeTreeGlob") (EVar "s")) (EApp (EVar "hasWholeTree") (EVar "ss"))))
(DTypeSig false "wholeTreeGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate"))))
(DFunDef false "wholeTreeGates" ((PList)) (EListLit))
(DFunDef false "wholeTreeGates" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "hasWholeTree") (EFieldAccess (EVar "g") "sources")) (EBinOp "::" (EVar "g") (EApp (EVar "wholeTreeGates") (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EVar "wholeTreeGates") (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fieldHit" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldHit" (PWild (PCon "False")) (EListLit))
(DFunDef false "fieldHit" ((PVar "field") (PCon "True")) (EListLit (EVar "field")))
(DTypeSig false "matchedFields" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchedFields" ((PVar "tok") (PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "fieldHit") (ELit (LString "run"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "run"))) (EApp (EApp (EVar "fieldHit") (ELit (LString "name"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "name")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "area"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "area")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "project"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "project")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "tier"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "tier")))))
(DTypeSig false "explainMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "explainMatches" (PWild (PList)) (EListLit))
(DFunDef false "explainMatches" ((PVar "tok") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "fs") (EApp (EApp (EVar "matchedFields") (EVar "tok")) (EVar "g"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "explainMatches") (EVar "tok")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "fs")) (EVar "rest") (EBinOp "::" (ETuple (EVar "g") (EVar "fs")) (EVar "rest"))))))
(DTypeSig false "isEmptyHits" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "isEmptyHits" ((PList)) (EVar "True"))
(DFunDef false "isEmptyHits" (PWild) (EVar "False"))
(DTypeSig false "renderGateLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderGateLines" ((PList)) (ELit (LString "")))
(DFunDef false "renderGateLines" ((PCons (PTuple (PVar "g") (PVar "rs")) (PVar "hs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  GATE      ")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rs")))) (ELit (LString ")\n"))) (EApp (EVar "renderGateLines") (EVar "hs"))))
(DTypeSig false "renderWholeTree" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderWholeTree" ((PList)) (ELit (LString "")))
(DFunDef false "renderWholeTree" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  GATE      ")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  (sources:*, whole-tree)\n"))) (EApp (EVar "renderWholeTree") (EVar "gs"))))
(DTypeSig false "renderTokenLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderTokenLines" ((PList)) (ELit (LString "")))
(DFunDef false "renderTokenLines" ((PCons (PTuple (PVar "g") (PVar "fs")) (PVar "hs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  TOKEN     ")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  (selector field: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "fs")))) (ELit (LString ")\n"))) (EApp (EVar "renderTokenLines") (EVar "hs"))))
(DTypeSig false "tokenSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String"))))
(DFunDef false "tokenSection" ((PVar "tok") (PVar "gates")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EVar "explainMatches") (EVar "tok")) (EVar "gates"))) (DoExpr (EIf (EApp (EVar "isEmptyHits") (EVar "hits")) (ELit (LString "")) (EApp (EVar "renderTokenLines") (EVar "hits"))))))
(DTypeSig false "blastNote" (TyCon "String"))
(DFunDef false "blastNote" () (EBinOp "++" (ELit (LString "  (registry-level policy, not per-entry data: a blast-radius path runs the\n")) (ELit (LString "   WHOLE suite whatever any entry's sources say — design doc §2.)\n"))))
(DTypeSig false "failOpenNote" (TyCon "String"))
(DFunDef false "failOpenNote" () (EBinOp "++" (ELit (LString "  (no entry's sources/corpus claims this path and it is not prose, so the\n")) (ELit (LString "   selection FAILS OPEN to the whole suite — never a silent empty set.)\n"))))
(DTypeSig false "proseNote" (TyCon "String"))
(DFunDef false "proseNote" () (EBinOp "++" (ELit (LString "  (prose: no entry claims it and it cannot widen the suite — ci.yml's own\n")) (ELit (LString "   docs allowlist, `detect` job.)\n"))))
(DTypeSig true "explainOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String"))))
(DFunDef false "explainOutput" ((PVar "path") (PVar "gates")) (EBlock (DoLet false false (PVar "wt") (EApp (EVar "renderWholeTree") (EApp (EVar "wholeTreeGates") (EVar "gates")))) (DoLet false false (PVar "tok") (EApp (EApp (EVar "tokenSection") (EVar "path")) (EVar "gates"))) (DoLet false false (PVar "hits") (EApp (EApp (EVar "explainPathHits") (EVar "path")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EVar "blastHit") (EVar "blastRadiusPrefixes")) (EVar "path")) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FULL      blast-radius:")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "\n"))) (EVar "blastNote")) (EVar "wt")) (EVar "tok"))) (arm (PCon "None") () (EIf (EApp (EVar "isEmptyHits") (EVar "hits")) (EBinOp "++" (EBinOp "++" (EIf (EApp (EVar "isProsePath") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  UNMAPPED  ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "\n"))) (EVar "proseNote")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  UNMAPPED  ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "\n  FULL      unmatched-non-prose:"))) (EApp (EVar "display") (EVar "path"))) (ELit (LString "\n"))) (EVar "failOpenNote"))) (EVar "wt")) (EVar "tok")) (EBinOp "++" (EBinOp "++" (EApp (EVar "renderGateLines") (EVar "hits")) (EVar "wt")) (EVar "tok"))))))))
(DData Private "ExplainArgs" () ((variant "ExplainArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "path" (TyApp (TyCon "Option") (TyCon "String"))) (field "prose" (TyCon "Bool"))))) ())
(DTypeSig false "parseExplainArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ExplainArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ExplainArgs")))))
(DFunDef false "parseExplainArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate explain: --registry needs a path"))))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--prose")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "prose" (EVar "True"))))))
(DFunDef false "parseExplainArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: unknown flag: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EMatch (EFieldAccess (EVar "acc") "path") (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "medaka gate explain: expected exactly one <path> argument")))) (arm (PCon "None") () (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "path" (EApp (EVar "Some") (EVar "a")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "explainCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "explainCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseExplainArgs") (EVar "argv")) (ERecordCreate "ExplainArgs" ((fa "registry" (EVar "None")) (fa "path" (EVar "None")) (fa "prose" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "path") (arm (PCon "None") () (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate explain <path> [--prose] [--registry <path>]"))))) (arm (PCon "Some" (PVar "tok")) () (EIf (EFieldAccess (EVar "a") "prose") (EApp (EVar "putStr") (EApp (EVar "proseVerdict") (EVar "tok"))) (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EVar "putStr") (EApp (EApp (EVar "explainOutput") (EVar "tok")) (EVar "gates")))))))))))))))
(DTypeSig false "ciWorkflowRel" (TyCon "String"))
(DFunDef false "ciWorkflowRel" () (ELit (LString ".github/workflows/ci.yml")))
(DTypeSig false "ciMatrixBegin" (TyCon "String"))
(DFunDef false "ciMatrixBegin" () (ELit (LString "          # GENERATED:BEGIN gates-matrix — `make gen-ci` (medaka gate ci) from test/gates.toml. DO NOT EDIT BY HAND.")))
(DTypeSig false "ciMatrixEnd" (TyCon "String"))
(DFunDef false "ciMatrixEnd" () (ELit (LString "          # GENERATED:END gates-matrix")))
(DTypeSig false "ciProseLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ciProseLine" ((PLit (LString ""))) (ELit (LString "            #")))
(DFunDef false "ciProseLine" ((PVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "            # ")) (EApp (EVar "display") (EVar "l"))) (ELit (LString ""))))
(DTypeSig false "dropTrailBlank" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropTrailBlank" ((PList)) (EListLit))
(DFunDef false "dropTrailBlank" ((PCons (PVar "x") (PList))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EListLit) (EIf (EVar "otherwise") (EListLit (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "dropTrailBlank" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropTrailBlank") (EVar "xs"))))
(DTypeSig false "ciQuotedNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "ciQuotedNames" ((PList)) (ELit (LString "")))
(DFunDef false "ciQuotedNames" ((PCons (PVar "g") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "'"))))
(DFunDef false "ciQuotedNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "' "))) (EApp (EVar "display") (EApp (EVar "ciQuotedNames") (EVar "gs")))) (ELit (LString ""))))
(DTypeSig false "ciShardGates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "ciShardGates" ((PVar "nm") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "nm")))) (EVar "gs")))
(DTypeSig false "ciOptLine" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciOptLine" (PWild (PCon "False")) (EListLit))
(DFunDef false "ciOptLine" ((PVar "key") (PCon "True")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "            ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ": \"1\"")))))
(DTypeSig false "ciRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Shard") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ciRowLines" ((PVar "rowGates") (PVar "prose") (PVar "sh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "          - name: ")) (EApp (EVar "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "")))) (EApp (EApp (EVar "map") (EVar "ciProseLine")) (EVar "prose"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "            pattern: \"")) (EApp (EVar "display") (EApp (EVar "ciQuotedNames") (EVar "rowGates")))) (ELit (LString "\""))))) (EApp (EApp (EVar "ciOptLine") (ELit (LString "full_cores"))) (EFieldAccess (EVar "sh") "fullCores"))) (EApp (EApp (EVar "ciOptLine") (ELit (LString "wasm_arm"))) (EFieldAccess (EVar "sh") "wasmArm"))))
(DTypeSig false "ciOneRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "Shard") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ciOneRow" ((PVar "root") (PVar "gates") (PVar "sh")) (EMatch (EApp (EApp (EVar "ciShardGates") (EFieldAccess (EVar "sh") "name")) (EVar "gates")) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: shard '")) (EApp (EVar "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "' has no gates in the registry — a row with an empty pattern fails its own shard in CI"))))) (arm (PVar "rowGates") () (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "sh") "rationale"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: shard '")) (EApp (EVar "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "': cannot read rationale "))) (EApp (EVar "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ciRowLines") (EVar "rowGates")) (EApp (EVar "dropTrailBlank") (EApp (EVar "splitNl") (EVar "src")))) (EVar "sh"))))))))
(DTypeSig false "ciRowsLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "ciRowsLoop" (PWild PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "ciRowsLoop" ((PVar "root") (PVar "gates") (PCons (PVar "sh") (PVar "shs")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "ciOneRow") (EVar "root")) (EVar "gates")) (EVar "sh")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "ls")) () (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "ls")) (EVar "acc"))))))
(DTypeSig false "ciKnownShard" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ciKnownShard" (PWild (PLit (LString "other-job"))) (EVar "True"))
(DFunDef false "ciKnownShard" ((PList) PWild) (EVar "False"))
(DFunDef false "ciKnownShard" ((PCons (PVar "sh") (PVar "shs")) (PVar "nm")) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "sh") "name") (EVar "nm")) (EApp (EApp (EVar "ciKnownShard") (EVar "shs")) (EVar "nm"))))
(DTypeSig false "ciUnknownShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciUnknownShards" (PWild (PList)) (EListLit))
(DFunDef false "ciUnknownShards" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "ciKnownShard") (EVar "shs")) (EFieldAccess (EVar "g") "shard")) (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (shard '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "shard"))) (ELit (LString "')"))) (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCountLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "ciCountLine" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "ciCountLine" ((PVar "want") (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "want")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "ciCountLine") (EVar "want")) (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ciCountLine") (EVar "want")) (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciIndexOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "ciIndexOf" (PWild (PList) PWild) (EUnOp "-" (ELit (LInt 1))))
(DFunDef false "ciIndexOf" ((PVar "want") (PCons (PVar "l") (PVar "ls")) (PVar "i")) (EIf (EBinOp "==" (EVar "l") (EVar "want")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "want")) (EVar "ls")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciAfterEnd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ciAfterEnd" ((PList)) (EListLit))
(DFunDef false "ciAfterEnd" ((PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "ciMatrixEnd")) (EBinOp "::" (EVar "l") (EVar "ls")) (EIf (EVar "otherwise") (EApp (EVar "ciAfterEnd") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciSpliceGo" (PWild (PList)) (EListLit))
(DFunDef false "ciSpliceGo" ((PVar "gen") (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "ciMatrixBegin")) (EBinOp "::" (EVar "l") (EBinOp "++" (EVar "gen") (EApp (EVar "ciAfterEnd") (EVar "ls")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EVar "ciSpliceGo") (EVar "gen")) (EVar "ls"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ciSplice" ((PVar "gen") (PVar "src")) (EIf (EBinOp "/=" (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixBegin")) (EVar "src")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "ciWorkflowRel"))) (ELit (LString " must contain exactly one BEGIN marker line (found "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixBegin")) (EVar "src"))))) (ELit (LString "):\n"))) (EApp (EVar "display") (EVar "ciMatrixBegin"))) (ELit (LString "")))) (EIf (EBinOp "/=" (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixEnd")) (EVar "src")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "ciWorkflowRel"))) (ELit (LString " must contain exactly one END marker line (found "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixEnd")) (EVar "src"))))) (ELit (LString "):\n"))) (EApp (EVar "display") (EVar "ciMatrixEnd"))) (ELit (LString "")))) (EIf (EBinOp "<" (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "ciMatrixEnd")) (EVar "src")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "ciMatrixBegin")) (EVar "src")) (ELit (LInt 0)))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "ciWorkflowRel"))) (ELit (LString ": the END marker precedes the BEGIN marker")))) (EIf (EVar "otherwise") (EApp (EVar "Ok") (EApp (EApp (EVar "ciSpliceGo") (EVar "gen")) (EVar "src"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Private "CiArgs" () ((variant "CiArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "workflow" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "parseCiArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CiArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "CiArgs")))))
(DFunDef false "parseCiArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --registry needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "workflow" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --workflow needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: unexpected argument: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "ciWorkflowPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ciWorkflowPath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "ciWorkflowPath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ciWorkflowRel")))
(DTypeSig false "ciNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "ciNewText" ((PVar "root") (PVar "regPath") (PVar "regSrc") (PVar "wfSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gates")) (arm (PList) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "gen")) () (EApp (EApp (EVar "map") (EVar "joinNl")) (EApp (EApp (EVar "ciSplice") (EVar "gen")) (EApp (EVar "splitNl") (EVar "wfSrc"))))))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "")))))))))))
(DTypeSig false "ciWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "ciWrite" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "wfPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot write ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: regenerated the gates matrix in ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "ciCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseCiArgs") (EVar "argv")) (ERecordCreate "CiArgs" ((fa "registry" (EVar "None")) (fa "workflow" (EVar "None"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "wfPath") (EApp (EApp (EVar "ciWorkflowPath") (EFieldAccess (EVar "a") "workflow")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "wfPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "wfSrc")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciNewText") (EVar "root")) (EVar "regPath")) (EVar "regSrc")) (EVar "wfSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "out")) () (EApp (EApp (EApp (EVar "ciWrite") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out")))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "getBool" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DData Public "Shard" () ((variant "Shard" (ConNamed (field "name" (TyCon "String")) (field "fullCores" (TyCon "Bool")) (field "wasmArm" (TyCon "Bool")) (field "rationale" (TyCon "String"))))) ())
(DTypeSig false "shardStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardBool" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "shardBool" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Ok") (EVar "b"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required boolean field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readShard" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShard" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "shard"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "full_cores"))) (EVar "e"))) (ELam ((PVar "fullCores")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "wasm_arm"))) (EVar "e"))) (ELam ((PVar "wasmArm")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "rationale"))) (EVar "e"))) (ELam ((PVar "rationale")) (EApp (EVar "Ok") (ERecordCreate "Shard" ((fa "name" (EVar "name")) (fa "fullCores" (EVar "fullCores")) (fa "wasmArm" (EVar "wasmArm")) (fa "rationale" (EVar "rationale"))))))))))))))))
(DTypeSig false "readShardsFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Shard"))))))))
(DFunDef false "readShardsFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseShards") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readShard") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "sh")) () (EApp (EApp (EApp (EApp (EVar "readShardsFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "sh") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Shard")))))
(DFunDef false "reverseShards" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseShards" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseShards") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig true "parseShards" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Shard")))))
(DFunDef false "parseShards" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "shard"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[shard]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readShardsFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
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
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig false "shardJson" (TyFun (TyCon "Shard") (TyCon "Json")))
(DFunDef false "shardJson" ((PVar "sh")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "name"))) (ETuple (ELit (LString "full_cores")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "fullCores"))) (ETuple (ELit (LString "wasm_arm")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "wasmArm"))) (ETuple (ELit (LString "rationale")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "rationale"))))))
(DTypeSig true "renderShardsJson" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShardsJson" ((PVar "shs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "shardJson")) (EVar "shs")))))
(DTypeSig false "boolWord" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolWord" ((PVar "b")) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig true "renderShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShards" ((PList)) (ELit (LString "")))
(DFunDef false "renderShards" ((PCons (PVar "sh") (PVar "shs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString ": full_cores="))) (EApp (EMethodRef "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "fullCores")))) (ELit (LString " wasm_arm="))) (EApp (EMethodRef "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "wasmArm")))) (ELit (LString " rationale="))) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString "\n"))) (EApp (EVar "renderShards") (EVar "shs"))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate ci      [--registry <path>] [--workflow <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, and no two entries\n")) (ELit (LString "share a `name`. Exits nonzero\n")) (ELit (LString "on any violation.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`; it is idempotent, so `git diff --exit-code` after a\n")) (ELit (LString "run is the drift check. The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "shards" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--shards")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "shards" (EVar "True"))))))
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
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "shards" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EIf (EFieldAccess (EVar "a") "shards") (EApp (EApp (EApp (EVar "shardsOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path"))))))))))))))
(DTypeSig false "shardsOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardsOutput" ((PVar "isJson") (PVar "tokens") (PVar "src")) (EIf (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EVar "tokens"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: --shards takes no selectors (got: ")) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString ")")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "parseShards") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderShardsJson") (EVar "shs")) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderShards") (EVar "shs")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run|verify|explain|ci> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EVar "verifyCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) (PVar "rest"))) (EApp (EVar "explainCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "ci")) (PVar "rest"))) (EApp (EVar "ciCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: list, run, verify, explain, ci)"))))))
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
(DTypeSig false "binTokenPrefix" (TyCon "String"))
(DFunDef false "binTokenPrefix" () (ELit (LString "test/bin/")))
(DTypeSig false "stripBinPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripBinPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "binTokenPrefix")) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "binTokenPrefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig false "scrapedOraclesIn" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "scrapedOraclesIn" ((PVar "scriptPath")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "grep"))) (EListLit (ELit (LString "-ohE")) (ELit (LString "test/bin/[a-z_0-9]+")) (EVar "scriptPath"))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EApp (EMethodRef "map") (EVar "stripBinPrefix")) (EApp (EApp (EVar "filterList") (EVar "nonBlankLine")) (EApp (EVar "splitNl") (EVar "out")))))))
(DTypeSig false "nonBlankLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonBlankLine" ((PVar "s")) (EBinOp "/=" (EApp (EVar "stringTrim") (EVar "s")) (ELit (LString ""))))
(DTypeSig false "scrapedOracles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "scrapedOracles" (PWild (PList)) (EListLit))
(DFunDef false "scrapedOracles" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EVar "scrapedOraclesIn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EApp (EApp (EVar "scrapedOracles") (EVar "root")) (EVar "gs"))))
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
(DFunDef false "staleRefusal" ((PCon "False") (PVar "root") (PVar "gs")) (EIf (EBinOp "||" (EApp (EVar "envSet") (ELit (LString "CI"))) (EApp (EVar "envSet") (ELit (LString "NO_STALE_CHECK")))) (EVar "None") (EBlock (DoLet false false (PVar "names") (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EVar "selectedOracles") (EVar "gs")) (EApp (EApp (EVar "scrapedOracles") (EVar "root")) (EVar "gs"))))) (DoLet false false (PVar "newest") (EApp (EVar "newestSourceMtime") (EVar "root"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "staleOf") (EVar "root")) (EVar "newest")) (EVar "names")) (arm (PList) () (EVar "None")) (arm (PVar "stale") () (EApp (EVar "Some") (EApp (EVar "staleBanner") (EVar "stale")))))))))
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
(DTypeSig false "nonBlank" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonBlank" ((PVar "s")) (EBinOp "/=" (EApp (EVar "stringTrim") (EVar "s")) (ELit (LString ""))))
(DTypeSig false "gitExitMsg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "gitExitMsg" ((PVar "code") (PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files exited ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files exited ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "")))))
(DTypeSig false "gitLsFilesSh" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "gitLsFilesSh" ((PVar "root") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "-C")) (EVar "root")) (EVar "args")) (EListLit (ELit (LString "*.sh"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files failed to run: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out"))))) (arm (PCon "Ok" (PTuple (PVar "code") PWild (PVar "err"))) () (EApp (EVar "Err") (EApp (EApp (EVar "gitExitMsg") (EVar "code")) (EApp (EVar "stringTrim") (EVar "err")))))))
(DTypeSig false "gateCandidates" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateCandidates" ((PVar "root")) (EMatch (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "tracked")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "untracked")) (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "tracked") (EVar "untracked"))))) (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")) (ELit (LString "-o")) (ELit (LString "--exclude-standard"))))))))
(DTypeSig false "liveLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "liveLine" ((PVar "l")) (EBinOp "&&" (EApp (EVar "nonBlank") (EVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "#"))) (EApp (EVar "stringTrim") (EVar "l"))))))
(DTypeSig false "firstToken" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstToken" ((PVar "l")) (EApp (EVar "firstNonBlankTok") (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "l"))))
(DTypeSig false "firstNonBlankTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonBlankTok" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonBlankTok" ((PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "nonBlank") (EVar "x")) (EVar "x") (EApp (EVar "firstNonBlankTok") (EVar "xs"))))
(DTypeSig false "toolNames" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "toolNames" ((PVar "root")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test/CI-COVERAGE-TOOLS.txt")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EApp (EMethodRef "map") (EVar "firstToken")) (EApp (EApp (EVar "filterList") (EVar "liveLine")) (EApp (EVar "splitNl") (EVar "src"))))))))
(DTypeSig false "stripSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSh" ((PVar "p")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".sh"))) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "p")) (ELit (LInt 3)))) (EVar "p")) (EVar "p")))
(DTypeSig false "allRuns" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allRuns" ((PList)) (EListLit))
(DFunDef false "allRuns" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EFieldAccess (EVar "g") "run") (EApp (EVar "allRuns") (EVar "gs"))))
(DTypeSig false "unenrolledViolations" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unenrolledViolations" (PWild PWild (PList)) (EListLit))
(DFunDef false "unenrolledViolations" ((PVar "tools") (PVar "runs") (PCons (PVar "c") (PVar "cs"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "stripSh") (EVar "c"))) (EVar "tools")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs")) (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "runs")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "unenrolled: ")) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString "  (not a `run` in test/gates.toml, not listed in test/CI-COVERAGE-TOOLS.txt)"))) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runTargetViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "runTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "runTargetViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "fileExists") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EVar "rest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": run target does not exist: "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString ""))) (EVar "rest"))))))
(DTypeSig false "knownOracles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "knownOracles" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/test/build_oracles.sh"))) (ELit (LString "--list")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out"))))))
(DTypeSig false "foreignOracles" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "foreignOracles" () (EListLit (ELit (LString "wasm_emit_main")) (ELit (LString "wasm_emit_modules_main"))))
(DTypeSig false "oracleNamesMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oracleNamesMissing" (PWild PWild (PList)) (EListLit))
(DFunDef false "oracleNamesMissing" ((PVar "known") (PVar "gname") (PCons (PVar "o") (PVar "os"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EVar "known")) (EApp (EApp (EVar "contains") (EVar "o")) (EVar "foreignOracles"))) (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EVar "gname")) (EVar "os")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gname"))) (ELit (LString ": oracle not known to `test/build_oracles.sh --list` (nor the wasm-foreign set): "))) (EApp (EMethodRef "display") (EVar "o"))) (ELit (LString ""))) (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EVar "gname")) (EVar "os"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "oracleTargetViolations" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oracleTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "oracleTargetViolations" ((PVar "known") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "oracleNamesMissing") (EVar "known")) (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "oracles")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gs"))))
(DTypeSig false "anyNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "Bool"))))
(DFunDef false "anyNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "anyNamed" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EApp (EVar "anyNamed") (EVar "n")) (EVar "gs"))))
(DTypeSig false "reachabilityFor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachabilityFor" ((PVar "all") (PVar "g")) (EMatch (EApp (EVar "parseSelector") (EFieldAccess (EVar "g") "name")) (arm (PCon "Err" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": its own name is not a valid bare selector ("))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ") — reachable only via an explicit `name:"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "`, not the bare CLI form"))))) (arm (PCon "Ok" (PVar "sel")) () (EIf (EApp (EApp (EVar "anyNamed") (EFieldAccess (EVar "g") "name")) (EApp (EApp (EVar "selectGates") (EListLit (EVar "sel"))) (EDictApp "all"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": `name:"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "` does not select this entry (registry/selector bug)"))))))))
(DTypeSig false "reachabilityViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachabilityViolations" (PWild (PList)) (EListLit))
(DFunDef false "reachabilityViolations" ((PVar "all") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "reachabilityFor") (EDictApp "all")) (EVar "g")) (EApp (EApp (EVar "reachabilityViolations") (EDictApp "all")) (EVar "gs"))))
(DTypeSig false "dirExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "dirExists" ((PVar "p")) (EMatch (EApp (EVar "listDir") (EVar "p")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EVar "True"))))
(DTypeSig false "corpusDirsMissing" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "corpusDirsMissing" (PWild PWild (PList)) (EListLit))
(DFunDef false "corpusDirsMissing" ((PVar "root") (PVar "gname") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "corpusDirsMissing") (EVar "root")) (EVar "gname")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "dirExists") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "c"))) (EVar "rest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gname"))) (ELit (LString ": corpus directory does not exist: "))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ""))) (EVar "rest"))))))
(DTypeSig false "corpusTargetViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "corpusTargetViolations" (PWild (PList)) (EListLit))
(DFunDef false "corpusTargetViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "corpusDirsMissing") (EVar "root")) (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "corpus")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gs"))))
(DTypeSig false "gateNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gateNames" ((PList)) (EListLit))
(DFunDef false "gateNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EVar "gateNames") (EVar "gs"))))
(DTypeSig false "countName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "Int"))))
(DFunDef false "countName" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countName" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EBinOp "+" (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "countName") (EVar "n")) (EVar "gs"))))
(DTypeSig false "dupNameFrom" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupNameFrom" (PWild (PList)) (EListLit))
(DFunDef false "dupNameFrom" ((PVar "gates") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "countName") (EVar "n")) (EVar "gates"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "dupNameFrom") (EVar "gates")) (EVar "ns"))) (DoExpr (EIf (EBinOp ">" (EVar "k") (ELit (LInt 1))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " entries share this name — a gate's shard row must not be ambiguous"))) (EVar "rest")) (EVar "rest")))))
(DTypeSig false "duplicateNameViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "duplicateNameViolations" ((PVar "gates")) (EApp (EApp (EVar "dupNameFrom") (EVar "gates")) (EApp (EVar "sortUniqS") (EApp (EVar "gateNames") (EVar "gates")))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))))))))))
(DTypeSig false "renderClass" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "OK    ")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": 0\n"))))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PVar "vs"))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "vs")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString "\n"))))))
(DTypeSig false "renderClasses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderClasses" ((PList)) (ELit (LString "")))
(DFunDef false "renderClasses" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "++" (EApp (EVar "renderClass") (EVar "c")) (EApp (EVar "renderClasses") (EVar "cs"))))
(DTypeSig false "totalViolations" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "totalViolations" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalViolations" ((PCons (PTuple PWild (PVar "vs")) (PVar "cs"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "vs")) (EApp (EVar "totalViolations") (EVar "cs"))))
(DTypeSig false "verifyOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "verifyOutput" ((PVar "root") (PVar "gates")) (EMatch (EApp (EApp (EVar "verifyClasses") (EVar "root")) (EVar "gates")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "classes")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "totalViolations") (EVar "classes"))) (DoLet false false (PVar "body") (EApp (EVar "renderClasses") (EVar "classes"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: OK — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries, 0 violations.\n"))))) (EApp (EVar "Err") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: FAIL — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " violation(s) across "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries.\n")))))))))))
(DData Private "VerifyArgs" () ((variant "VerifyArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "parseVerifyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "VerifyArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "VerifyArgs")))))
(DFunDef false "parseVerifyArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseVerifyArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseVerifyArgs") (EVar "rest")) (EVariantUpdate "VerifyArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseVerifyArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate verify: --registry needs a path"))))
(DFunDef false "parseVerifyArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: unknown flag: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "verifyCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseVerifyArgs") (EVar "argv")) (ERecordCreate "VerifyArgs" ((fa "registry" (EVar "None"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EVar "emit") (EApp (EApp (EVar "verifyOutput") (EVar "root")) (EVar "gates"))))))))))))))
(DTypeSig true "blastRadiusPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "blastRadiusPrefixes" () (EListLit (ELit (LString "compiler/support/*")) (ELit (LString "compiler/entries/*")) (ELit (LString "stdlib/*")) (ELit (LString "runtime/*"))))
(DTypeSig false "blastHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "blastHit" ((PList) PWild) (EVar "None"))
(DFunDef false "blastHit" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "path")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "blastHit") (EVar "ps")) (EVar "path"))))
(DTypeSig true "isProsePath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isProsePath" ((PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test/"))) (EVar "p")) (EVar "False") (EIf (EBinOp "==" (EVar "p") (ELit (LString "docs/spec/SYNTAX.md"))) (EVar "False") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "docs/"))) (EVar "p")) (EVar "True") (EIf (EBinOp "==" (EVar "p") (ELit (LString "LICENSE"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "LICENSE."))) (EVar "p")) (EVar "True") (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p")) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "proseVerdict" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "proseVerdict" ((PVar "p")) (EIf (EApp (EVar "isProsePath") (EVar "p")) (ELit (LString "PROSE\n")) (ELit (LString "NONDOC\n"))))
(DTypeSig false "wholeTreeGlob" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "wholeTreeGlob" ((PVar "g")) (EBinOp "==" (EVar "g") (ELit (LString "*"))))
(DTypeSig false "sourceMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sourceMatches" (PWild (PList)) (EListLit))
(DFunDef false "sourceMatches" ((PVar "path") (PCons (PVar "s") (PVar "ss"))) (EIf (EApp (EVar "wholeTreeGlob") (EVar "s")) (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss")) (EIf (EApp (EApp (EVar "globMatch") (EVar "s")) (EVar "path")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "sources:")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ""))) (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "underDir" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "underDir" ((PVar "d") (PVar "path")) (EBinOp "||" (EBinOp "==" (EVar "path") (EVar "d")) (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString "/")))) (EVar "path"))))
(DTypeSig false "corpusMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "corpusMatches" (PWild (PList)) (EListLit))
(DFunDef false "corpusMatches" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EApp (EApp (EVar "underDir") (EVar "c")) (EVar "path")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "corpus:")) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ""))) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "targetedReasons" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "targetedReasons" ((PVar "path") (PVar "g")) (EBinOp "++" (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EFieldAccess (EVar "g") "sources")) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EFieldAccess (EVar "g") "corpus"))))
(DTypeSig false "explainPathHits" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "explainPathHits" (PWild (PList)) (EListLit))
(DFunDef false "explainPathHits" ((PVar "path") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EVar "targetedReasons") (EVar "path")) (EVar "g"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "explainPathHits") (EVar "path")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "rs")) (EVar "rest") (EBinOp "::" (ETuple (EVar "g") (EVar "rs")) (EVar "rest"))))))
(DTypeSig false "hasWholeTree" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasWholeTree" ((PList)) (EVar "False"))
(DFunDef false "hasWholeTree" ((PCons (PVar "s") (PVar "ss"))) (EBinOp "||" (EApp (EVar "wholeTreeGlob") (EVar "s")) (EApp (EVar "hasWholeTree") (EVar "ss"))))
(DTypeSig false "wholeTreeGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate"))))
(DFunDef false "wholeTreeGates" ((PList)) (EListLit))
(DFunDef false "wholeTreeGates" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "hasWholeTree") (EFieldAccess (EVar "g") "sources")) (EBinOp "::" (EVar "g") (EApp (EVar "wholeTreeGates") (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EVar "wholeTreeGates") (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fieldHit" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldHit" (PWild (PCon "False")) (EListLit))
(DFunDef false "fieldHit" ((PVar "field") (PCon "True")) (EListLit (EVar "field")))
(DTypeSig false "matchedFields" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchedFields" ((PVar "tok") (PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "fieldHit") (ELit (LString "run"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "run"))) (EApp (EApp (EVar "fieldHit") (ELit (LString "name"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "name")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "area"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "area")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "project"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "project")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "tier"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "tier")))))
(DTypeSig false "explainMatches" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "explainMatches" (PWild (PList)) (EListLit))
(DFunDef false "explainMatches" ((PVar "tok") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "fs") (EApp (EApp (EVar "matchedFields") (EVar "tok")) (EVar "g"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "explainMatches") (EVar "tok")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "fs")) (EVar "rest") (EBinOp "::" (ETuple (EVar "g") (EVar "fs")) (EVar "rest"))))))
(DTypeSig false "isEmptyHits" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "isEmptyHits" ((PList)) (EVar "True"))
(DFunDef false "isEmptyHits" (PWild) (EVar "False"))
(DTypeSig false "renderGateLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderGateLines" ((PList)) (ELit (LString "")))
(DFunDef false "renderGateLines" ((PCons (PTuple (PVar "g") (PVar "rs")) (PVar "hs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  GATE      ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rs")))) (ELit (LString ")\n"))) (EApp (EVar "renderGateLines") (EVar "hs"))))
(DTypeSig false "renderWholeTree" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderWholeTree" ((PList)) (ELit (LString "")))
(DFunDef false "renderWholeTree" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  GATE      ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  (sources:*, whole-tree)\n"))) (EApp (EVar "renderWholeTree") (EVar "gs"))))
(DTypeSig false "renderTokenLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderTokenLines" ((PList)) (ELit (LString "")))
(DFunDef false "renderTokenLines" ((PCons (PTuple (PVar "g") (PVar "fs")) (PVar "hs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  TOKEN     ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "  (selector field: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "fs")))) (ELit (LString ")\n"))) (EApp (EVar "renderTokenLines") (EVar "hs"))))
(DTypeSig false "tokenSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String"))))
(DFunDef false "tokenSection" ((PVar "tok") (PVar "gates")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EVar "explainMatches") (EVar "tok")) (EVar "gates"))) (DoExpr (EIf (EApp (EVar "isEmptyHits") (EVar "hits")) (ELit (LString "")) (EApp (EVar "renderTokenLines") (EVar "hits"))))))
(DTypeSig false "blastNote" (TyCon "String"))
(DFunDef false "blastNote" () (EBinOp "++" (ELit (LString "  (registry-level policy, not per-entry data: a blast-radius path runs the\n")) (ELit (LString "   WHOLE suite whatever any entry's sources say — design doc §2.)\n"))))
(DTypeSig false "failOpenNote" (TyCon "String"))
(DFunDef false "failOpenNote" () (EBinOp "++" (ELit (LString "  (no entry's sources/corpus claims this path and it is not prose, so the\n")) (ELit (LString "   selection FAILS OPEN to the whole suite — never a silent empty set.)\n"))))
(DTypeSig false "proseNote" (TyCon "String"))
(DFunDef false "proseNote" () (EBinOp "++" (ELit (LString "  (prose: no entry claims it and it cannot widen the suite — ci.yml's own\n")) (ELit (LString "   docs allowlist, `detect` job.)\n"))))
(DTypeSig true "explainOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String"))))
(DFunDef false "explainOutput" ((PVar "path") (PVar "gates")) (EBlock (DoLet false false (PVar "wt") (EApp (EVar "renderWholeTree") (EApp (EVar "wholeTreeGates") (EVar "gates")))) (DoLet false false (PVar "tok") (EApp (EApp (EVar "tokenSection") (EVar "path")) (EVar "gates"))) (DoLet false false (PVar "hits") (EApp (EApp (EVar "explainPathHits") (EVar "path")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EVar "blastHit") (EVar "blastRadiusPrefixes")) (EVar "path")) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FULL      blast-radius:")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "\n"))) (EVar "blastNote")) (EVar "wt")) (EVar "tok"))) (arm (PCon "None") () (EIf (EApp (EVar "isEmptyHits") (EVar "hits")) (EBinOp "++" (EBinOp "++" (EIf (EApp (EVar "isProsePath") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  UNMAPPED  ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "\n"))) (EVar "proseNote")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  UNMAPPED  ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "\n  FULL      unmatched-non-prose:"))) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "\n"))) (EVar "failOpenNote"))) (EVar "wt")) (EVar "tok")) (EBinOp "++" (EBinOp "++" (EApp (EVar "renderGateLines") (EVar "hits")) (EVar "wt")) (EVar "tok"))))))))
(DData Private "ExplainArgs" () ((variant "ExplainArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "path" (TyApp (TyCon "Option") (TyCon "String"))) (field "prose" (TyCon "Bool"))))) ())
(DTypeSig false "parseExplainArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ExplainArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ExplainArgs")))))
(DFunDef false "parseExplainArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate explain: --registry needs a path"))))
(DFunDef false "parseExplainArgs" ((PCons (PLit (LString "--prose")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "prose" (EVar "True"))))))
(DFunDef false "parseExplainArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: unknown flag: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EMatch (EFieldAccess (EVar "acc") "path") (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "medaka gate explain: expected exactly one <path> argument")))) (arm (PCon "None") () (EApp (EApp (EVar "parseExplainArgs") (EVar "rest")) (EVariantUpdate "ExplainArgs" (EVar "acc") ((fa "path" (EApp (EVar "Some") (EVar "a")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "explainCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "explainCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseExplainArgs") (EVar "argv")) (ERecordCreate "ExplainArgs" ((fa "registry" (EVar "None")) (fa "path" (EVar "None")) (fa "prose" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "path") (arm (PCon "None") () (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate explain <path> [--prose] [--registry <path>]"))))) (arm (PCon "Some" (PVar "tok")) () (EIf (EFieldAccess (EVar "a") "prose") (EApp (EVar "putStr") (EApp (EVar "proseVerdict") (EVar "tok"))) (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EVar "putStr") (EApp (EApp (EVar "explainOutput") (EVar "tok")) (EVar "gates")))))))))))))))
(DTypeSig false "ciWorkflowRel" (TyCon "String"))
(DFunDef false "ciWorkflowRel" () (ELit (LString ".github/workflows/ci.yml")))
(DTypeSig false "ciMatrixBegin" (TyCon "String"))
(DFunDef false "ciMatrixBegin" () (ELit (LString "          # GENERATED:BEGIN gates-matrix — `make gen-ci` (medaka gate ci) from test/gates.toml. DO NOT EDIT BY HAND.")))
(DTypeSig false "ciMatrixEnd" (TyCon "String"))
(DFunDef false "ciMatrixEnd" () (ELit (LString "          # GENERATED:END gates-matrix")))
(DTypeSig false "ciProseLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ciProseLine" ((PLit (LString ""))) (ELit (LString "            #")))
(DFunDef false "ciProseLine" ((PVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "            # ")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString ""))))
(DTypeSig false "dropTrailBlank" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropTrailBlank" ((PList)) (EListLit))
(DFunDef false "dropTrailBlank" ((PCons (PVar "x") (PList))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EListLit) (EIf (EVar "otherwise") (EListLit (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "dropTrailBlank" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropTrailBlank") (EVar "xs"))))
(DTypeSig false "ciQuotedNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "ciQuotedNames" ((PList)) (ELit (LString "")))
(DFunDef false "ciQuotedNames" ((PCons (PVar "g") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "'"))))
(DFunDef false "ciQuotedNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "' "))) (EApp (EMethodRef "display") (EApp (EVar "ciQuotedNames") (EVar "gs")))) (ELit (LString ""))))
(DTypeSig false "ciShardGates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "ciShardGates" ((PVar "nm") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "nm")))) (EVar "gs")))
(DTypeSig false "ciOptLine" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciOptLine" (PWild (PCon "False")) (EListLit))
(DFunDef false "ciOptLine" ((PVar "key") (PCon "True")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "            ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ": \"1\"")))))
(DTypeSig false "ciRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Shard") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ciRowLines" ((PVar "rowGates") (PVar "prose") (PVar "sh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "          - name: ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "")))) (EApp (EApp (EMethodRef "map") (EVar "ciProseLine")) (EVar "prose"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "            pattern: \"")) (EApp (EMethodRef "display") (EApp (EVar "ciQuotedNames") (EVar "rowGates")))) (ELit (LString "\""))))) (EApp (EApp (EVar "ciOptLine") (ELit (LString "full_cores"))) (EFieldAccess (EVar "sh") "fullCores"))) (EApp (EApp (EVar "ciOptLine") (ELit (LString "wasm_arm"))) (EFieldAccess (EVar "sh") "wasmArm"))))
(DTypeSig false "ciOneRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "Shard") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ciOneRow" ((PVar "root") (PVar "gates") (PVar "sh")) (EMatch (EApp (EApp (EVar "ciShardGates") (EFieldAccess (EVar "sh") "name")) (EVar "gates")) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: shard '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "' has no gates in the registry — a row with an empty pattern fails its own shard in CI"))))) (arm (PVar "rowGates") () (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "sh") "rationale"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: shard '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString "': cannot read rationale "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ciRowLines") (EVar "rowGates")) (EApp (EVar "dropTrailBlank") (EApp (EVar "splitNl") (EVar "src")))) (EVar "sh"))))))))
(DTypeSig false "ciRowsLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "ciRowsLoop" (PWild PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "ciRowsLoop" ((PVar "root") (PVar "gates") (PCons (PVar "sh") (PVar "shs")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "ciOneRow") (EVar "root")) (EVar "gates")) (EVar "sh")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "ls")) () (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "ls")) (EVar "acc"))))))
(DTypeSig false "ciKnownShard" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ciKnownShard" (PWild (PLit (LString "other-job"))) (EVar "True"))
(DFunDef false "ciKnownShard" ((PList) PWild) (EVar "False"))
(DFunDef false "ciKnownShard" ((PCons (PVar "sh") (PVar "shs")) (PVar "nm")) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "sh") "name") (EVar "nm")) (EApp (EApp (EVar "ciKnownShard") (EVar "shs")) (EVar "nm"))))
(DTypeSig false "ciUnknownShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciUnknownShards" (PWild (PList)) (EListLit))
(DFunDef false "ciUnknownShards" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "ciKnownShard") (EVar "shs")) (EFieldAccess (EVar "g") "shard")) (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (shard '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "shard"))) (ELit (LString "')"))) (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCountLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "ciCountLine" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "ciCountLine" ((PVar "want") (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "want")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "ciCountLine") (EVar "want")) (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ciCountLine") (EVar "want")) (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciIndexOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "ciIndexOf" (PWild (PList) PWild) (EUnOp "-" (ELit (LInt 1))))
(DFunDef false "ciIndexOf" ((PVar "want") (PCons (PVar "l") (PVar "ls")) (PVar "i")) (EIf (EBinOp "==" (EVar "l") (EVar "want")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "want")) (EVar "ls")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciAfterEnd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ciAfterEnd" ((PList)) (EListLit))
(DFunDef false "ciAfterEnd" ((PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "ciMatrixEnd")) (EBinOp "::" (EVar "l") (EVar "ls")) (EIf (EVar "otherwise") (EApp (EVar "ciAfterEnd") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ciSpliceGo" (PWild (PList)) (EListLit))
(DFunDef false "ciSpliceGo" ((PVar "gen") (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "l") (EVar "ciMatrixBegin")) (EBinOp "::" (EVar "l") (EBinOp "++" (EVar "gen") (EApp (EVar "ciAfterEnd") (EVar "ls")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EVar "ciSpliceGo") (EVar "gen")) (EVar "ls"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ciSplice" ((PVar "gen") (PVar "src")) (EIf (EBinOp "/=" (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixBegin")) (EVar "src")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "ciWorkflowRel"))) (ELit (LString " must contain exactly one BEGIN marker line (found "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixBegin")) (EVar "src"))))) (ELit (LString "):\n"))) (EApp (EMethodRef "display") (EVar "ciMatrixBegin"))) (ELit (LString "")))) (EIf (EBinOp "/=" (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixEnd")) (EVar "src")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "ciWorkflowRel"))) (ELit (LString " must contain exactly one END marker line (found "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "ciCountLine") (EVar "ciMatrixEnd")) (EVar "src"))))) (ELit (LString "):\n"))) (EApp (EMethodRef "display") (EVar "ciMatrixEnd"))) (ELit (LString "")))) (EIf (EBinOp "<" (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "ciMatrixEnd")) (EVar "src")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "ciIndexOf") (EVar "ciMatrixBegin")) (EVar "src")) (ELit (LInt 0)))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "ciWorkflowRel"))) (ELit (LString ": the END marker precedes the BEGIN marker")))) (EIf (EVar "otherwise") (EApp (EVar "Ok") (EApp (EApp (EVar "ciSpliceGo") (EVar "gen")) (EVar "src"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Private "CiArgs" () ((variant "CiArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "workflow" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "parseCiArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CiArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "CiArgs")))))
(DFunDef false "parseCiArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --registry needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "workflow" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --workflow needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: unexpected argument: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "ciWorkflowPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ciWorkflowPath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "ciWorkflowPath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ciWorkflowRel")))
(DTypeSig false "ciNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "ciNewText" ((PVar "root") (PVar "regPath") (PVar "regSrc") (PVar "wfSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gates")) (arm (PList) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "gen")) () (EApp (EApp (EMethodRef "map") (EVar "joinNl")) (EApp (EApp (EVar "ciSplice") (EVar "gen")) (EApp (EVar "splitNl") (EVar "wfSrc"))))))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "")))))))))))
(DTypeSig false "ciWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "ciWrite" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "wfPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot write ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: regenerated the gates matrix in ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "ciCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseCiArgs") (EVar "argv")) (ERecordCreate "CiArgs" ((fa "registry" (EVar "None")) (fa "workflow" (EVar "None"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "wfPath") (EApp (EApp (EVar "ciWorkflowPath") (EFieldAccess (EVar "a") "workflow")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "wfPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "wfSrc")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciNewText") (EVar "root")) (EVar "regPath")) (EVar "regSrc")) (EVar "wfSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "out")) () (EApp (EApp (EApp (EVar "ciWrite") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out")))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
