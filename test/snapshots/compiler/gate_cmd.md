# META
source_lines=5288
stages=DESUGAR,MARK
# SOURCE
{- gate_cmd.mdk — `medaka gate`, the gate-registry driver (#2176, epic #2182).

   Four commands: `medaka gate list [<selector>...] [--json]` (the read path —
   the registry schema `test/gates.toml`, a reader for it, and the selector
   language), `medaka gate run [<selector>...]`, which EXECUTES the selected
   gates, `medaka gate verify` (the drift gate: TEXT-ONLY, no build — every
   gate candidate enrolled-or-ledgered, every entry's `run`/`oracles`/`corpus`
   targets exist, every entry reachable by a selector, every `name` unique and
   inside a charset safe to interpolate into YAML and into a shell word)
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
import driver.loader.{readDeps}
import support.path.{joinPath}
import args.{
  ArgSpec,
  Args,
  Trailing(..),
  spec,
  switch,
  value,
  withTrailing,
  withStrictDash,
  parseArgs,
  flag,
  flagValue,
  unknownFlagMessage,
  missingValueMessage,
}
import tools.gate_cost.{
  GateCost,
  RunRecord,
  baselineKey,
  costOf,
  costRowOf,
  gateSetDigest,
  latestRunForShard,
  packStat,
  parseCostBaseline,
  parseCostRuns,
}
import support.util.{
  contains,
  endsWith,
  filterList,
  joinNl,
  joinWith,
  listLen,
  maxI,
  minI,
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
--
-- ── `tiers` (S-tier-is-data, #2181) ─────────────────────────────────────────
--
-- `tiers` is the SET OF RUNS this gate has: not one string, because "when does
-- this gate run" has never had one answer.  Two gates in the committed tree run
-- at two tiers at once (`diff_compiler_eval_scaling` on the merge path AND in
-- nightly's `eval-scaling` job; `diff_compiler_perf_scaling` on the merge path
-- AND in nightly's `perf-scaling-deep` job with `PERF_DEEP=1`), and the old
-- single `tier : String` could record neither — it recorded `merge` for both
-- and the nightly half of each was invisible to every consumer.
--
-- Each element is a RUN TOKEN, `<tier>` or `<tier>/<mode>`:
--
--   <tier>  `merge` (the PR/merge-queue path), `nightly` (the scheduled
--           workflow), or `ondemand` (nothing invokes it automatically).
--   <mode>  the INVOCATION DELTA: the comma-joined, sorted `KEY=VALUE`
--           environment assignments the invoking step sets that change what the
--           gate does.  It is DATA, not a label — `nightly/PERF_DEEP=1` says
--           exactly what makes that run different, which is what lets
--           `test/diff_compiler_tier_drift.sh` CHECK it against the workflow
--           instead of taking a prose word for it.  A bare `nightly` next to a
--           bare `merge` is therefore a positive claim of DUPLICATION: the two
--           runs are the identical invocation.
--
-- INVARIANTS (checked by `gate verify`, check 9): non-empty; every token's tier
-- part is one of the three; no duplicate tokens; `ondemand` appears only alone
-- and never carries a mode (a gate nothing invokes has no invocation to differ
-- from).  The list is kept in sorted order so a diff of the registry reads as a
-- change of fact, not a reordering.

public export data Gate = Gate {
  name : String,
  area : String,
  shard : String,
  project : String,
  tiers : List String,
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
  None =>
    Err
      "gates.toml: [[gate]] #\{intToString i}: missing required string field '\{field}'"

-- Pull one required string-array field.  Present-but-empty is fine; absent is
-- not (see the schema note above).
reqArr : Int -> String -> Toml -> Result String (List String)
reqArr i field entry = match getArray field entry
  Some xs => Ok xs
  None =>
    Err
      "gates.toml: [[gate]] #\{intToString i}: missing required array field '\{field}'"

readGate : Toml -> Int -> Result String Gate
readGate doc i = match tableEntry "gate" i doc
  None => Err "gates.toml: [[gate]] #\{intToString i}: no such entry"
  Some e => readGateEntry i e

readGateEntry : Int -> Toml -> Result String Gate
readGateEntry i e = do
  name <- reqStr i "name" e
  area <- reqStr i "area" e
  shard <- reqStr i "shard" e
  project <- reqStr i "project" e
  tiers <- reqArr i "tiers" e
  cost <- reqStr i "cost" e
  kind <- reqStr i "kind" e
  run <- reqStr i "run" e
  oracles <- reqArr i "oracles" e
  sources <- reqArr i "sources" e
  corpus <- reqArr i "corpus" e
  toolchain <- reqArr i "toolchain" e
  Ok Gate {
    name = name,
    area = area,
    shard = shard,
    project = project,
    tiers = tiers,
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
    Ok g => readGatesFrom doc (i + 1) n (g :: acc)

reverseGates : List Gate -> List Gate -> List Gate
reverseGates [] acc = acc
reverseGates (g :: gs) acc = reverseGates gs (g :: acc)

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
-- `pinned_gates` is the row's DECLARED membership, checked by the balancer
-- (`balPinErrors`).  A closed (`full_cores`) row lists exactly the gates that
-- must name it; an open row lists nothing, because its membership is the
-- packer's output.
--
-- `rationale` is a PATH (`test/gate_shards/<name>.txt`), not the prose itself:
-- the TOML subset this reader is built on has no multi-line string, and 180
-- lines of English on one line would be worse than no home at all.  Nothing
-- here reads that file — `medaka gate list --shards` prints the path, and the
-- ci.yml generator (S-2) is what will read it and emit it verbatim as the
-- row's comment block.

public export data Shard = Shard {
  name : String,
  fullCores : Bool,
  wasmArm : Bool,
  rationale : String,
  pinned : List String,
}

shardStr : Int -> String -> Toml -> Result String String
shardStr i field entry = match getString field entry
  Some s => Ok s
  None =>
    Err
      "gates.toml: [[shard]] #\{intToString i}: missing required string field '\{field}'"

-- Present-or-error, like every other field: an ABSENT `wasm_arm` must not
-- silently read as `false`.  In ci.yml the key IS absent when the option is
-- off, but that is the GENERATOR's encoding of `false`, not the registry's —
-- a row that simply forgot the key would otherwise lose its Wasm toolchain
-- and take its gates' Wasm arms down quietly with it.
shardBool : Int -> String -> Toml -> Result String Bool
shardBool i field entry = match getBool field entry
  Some b => Ok b
  None =>
    Err
      "gates.toml: [[shard]] #\{intToString i}: missing required boolean field '\{field}'"

-- Likewise for the row's declared closed-row membership.  Present-but-empty is
-- the normal reading on an OPEN row; ABSENT is an error, because an absent
-- `pinned_gates` read as `[]` would make a closed row's membership check
-- vacuously true — the exact hole this field exists to close.
shardArr : Int -> String -> Toml -> Result String (List String)
shardArr i field entry = match getArray field entry
  Some xs => Ok xs
  None =>
    Err
      "gates.toml: [[shard]] #\{intToString i}: missing required array field '\{field}'"

readShard : Toml -> Int -> Result String Shard
readShard doc i = match tableEntry "shard" i doc
  None => Err "gates.toml: [[shard]] #\{intToString i}: no such entry"
  Some e => readShardEntry i e

readShardEntry : Int -> Toml -> Result String Shard
readShardEntry i e = do
  name <- shardStr i "name" e
  fullCores <- shardBool i "full_cores" e
  wasmArm <- shardBool i "wasm_arm" e
  rationale <- shardStr i "rationale" e
  pinned <- shardArr i "pinned_gates" e
  Ok Shard {
    name = name,
    fullCores = fullCores,
    wasmArm = wasmArm,
    rationale = rationale,
    pinned = pinned,
  }

readShardsFrom : Toml -> Int -> Int -> List Shard -> Result String (List Shard)
readShardsFrom doc i n acc
  | i >= n = Ok (reverseShards acc [])
  | otherwise = match readShard doc i
    Err m => Err m
    Ok sh => readShardsFrom doc (i + 1) n (sh :: acc)

reverseShards : List Shard -> List Shard -> List Shard
reverseShards [] acc = acc
reverseShards (s :: ss) acc = reverseShards ss (s :: acc)

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
            Err
              "unknown selector field in '\{tok}' (expected name:, area:, project: or tier:)"
          else
            Ok (SelName tok)

{- | Does a gate satisfy one selector?  Every field is glob-matched, so a
   literal value is an exact match and `area:back*` also works. -}
export
matchesSelector : Selector -> Gate -> Bool
matchesSelector (SelName p) g = globMatch p g.name
matchesSelector (SelArea p) g = globMatch p g.area
matchesSelector (SelProject p) g = globMatch p g.project
matchesSelector (SelTier p) g = anyTierMatch p g.tiers

{- | `tier:` is the one selector over a LIST, so it needs a rule the other three
   do not: which of a gate's run tokens does the glob have to match?

   BOTH the whole token and its tier part, either one.  `tier:nightly` therefore
   selects every gate that runs nightly IN ANY MODE — including one declared
   `nightly/PERF_DEEP=1` — and `tier:nightly/PERF_DEEP=1` selects only that mode.
   Matching the whole token alone would have made `tier:nightly` silently NARROW
   the day a mode was declared, and a narrowing selector still matches gates, so
   the "a selector matching zero gates is an error" rule could never catch it. -}
export
anyTierMatch : String -> List String -> Bool
anyTierMatch _ [] = False
anyTierMatch p (t :: ts)
  | globMatch p t = True
  | globMatch p (tierPartOf t) = True
  | otherwise = anyTierMatch p ts

{- | A run token's tier part: everything before the first `/`.

   > tierPartOf "nightly/PERF_DEEP=1" == "nightly"
   True

   > tierPartOf "merge" == "merge"
   True -}
export
tierPartOf : String -> String
tierPartOf tok = match splitOnChar '/' tok
  [] => tok
  t :: _ => t

{- | A run token's mode part: everything after the first `/`, or `""`.

   > modePartOf "nightly/PERF_DEEP=1" == "PERF_DEEP=1"
   True

   > modePartOf "merge" == ""
   True -}
export
modePartOf : String -> String
modePartOf tok =
  let n = stringLength (tierPartOf tok)
  if n >= stringLength tok then
    ""
  else
    stringSlice (n + 1) (stringLength tok) tok

-- Conjunction: a gate must satisfy EVERY selector given.
matchesAll : List Selector -> Gate -> Bool
matchesAll [] _ = True
matchesAll (s :: ss) g = matchesSelector s g && matchesAll ss g

{- | Select the gates matching every selector, preserving registry order. -}
export
selectGates : List Selector -> List Gate -> List Gate
selectGates _ [] = []
selectGates sels (g :: gs)
  | matchesAll sels g = g :: selectGates sels gs
  | otherwise = selectGates sels gs

-- ── Rendering ───────────────────────────────────────────────────────────────

renderNames : List Gate -> String
renderNames [] = ""
renderNames (g :: gs) = "\{g.name}\n" ++ renderNames gs

gateJson : Gate -> Json
gateJson g = jObject [
  ("name", JString g.name),
  ("baselineKey", JString (baselineKey g.run)),
  ("area", JString g.area),
  ("shard", JString g.shard),
  ("project", JString g.project),
  ("tiers", jArray (map JString g.tiers)),
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
shardJson sh = jObject [
  ("name", JString sh.name),
  ("full_cores", JBool sh.fullCores),
  ("wasm_arm", JBool sh.wasmArm),
  ("rationale", JString sh.rationale),
  ("pinned_gates", jArray (map JString sh.pinned)),
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
renderShards (sh :: shs) =
  "\{sh.name}: full_cores=\{boolWord sh.fullCores} wasm_arm=\{boolWord sh.wasmArm} rationale=\{sh.rationale} pinned_gates=[\{joinSpace sh.pinned}]\n"
    ++ renderShards shs

-- ── CLI ─────────────────────────────────────────────────────────────────────

export
gateHelpText : String
gateHelpText = stringConcat [
  "medaka gate — Query the gate registry (test/gates.toml)\n", "\n", "Usage:\n",
  "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n",
  "  medaka gate list    --shards [--json] [--registry <path>]\n",
  "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n",
  "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n",
  "                      [--registry <path>]\n",
  "  medaka gate verify  [--registry <path>]\n",
  "  medaka gate explain <path> [--prose] [--registry <path>]\n",
  "  medaka gate reach   [<changed-path>...] [--paths-from <file>] [--json]\n",
  "                      [--registry <path>] [--root <path>]\n",
  "  medaka gate ci      [--check] [--registry <path>] [--workflow <path>]\n",
  "  medaka gate balance [--check] [--registry <path>] [--baseline <path>]\n",
  "  medaka gate budget  [--registry <path>] [--baseline <path>]\n",
  "                      [--commit-message <text>]\n", "\n",
  "Selectors (conjunction — a gate must match all of them):\n",
  "  name:<glob>      gate name, e.g. name:diff_compiler_*\n",
  "  area:<glob>      semantic area, e.g. area:backend\n",
  "  project:<glob>   owning project, e.g. project:sqlite\n",
  "  tier:<glob>      a RUN of this gate: merge | nightly | ondemand, optionally\n",
  "                   /<mode> (the invocation delta, e.g. nightly/PERF_DEEP=1).\n",
  "                   A gate can have several; the glob matches a whole token or\n",
  "                   its tier part, so tier:nightly selects every mode.\n",
  "  <glob>           sugar for name:<glob>\n", "\n",
  "A selector matching zero gates is an error, not an empty list.\n", "\n",
  "  --json             list: the registry entries as JSON.\n",
  "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n",
  "                     run: the machine-readable run report as JSON.\n",
  "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n",
  "\n", "`gate balance` only:\n",
  "  --check            derive the assignment in memory and report whether the\n",
  "                     committed one matches it; write nothing\n",
  "  --baseline <path>  read this cost baseline instead of\n",
  "                     <MEDAKA_ROOT>/test/gate_cost_baseline.json\n", "\n",
  "`gate balance` CHOOSES each gate's `shard` row from the registry's own\n",
  "constraints plus the measured cost baseline, and rewrites the `shard = \"...\"`\n",
  "lines in test/gates.toml in place. A full_cores row is CLOSED: its members\n",
  "are declared by that [[shard]] row's `pinned_gates` and checked in both\n",
  "directions, so they are neither packed nor hand-assignable. A gate needing\n",
  "wasm-tools/node only lands on a\n",
  "row with wasm_arm = true. It refuses rather than pack from a missing cost,\n",
  "and fails when the assignment it would emit misses its pole/floor budget.\n",
  "\n", "`gate run` only:\n",
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
  "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n", "\n",
  "`gate verify` is the drift gate: text-only, no build. Checks every gate\n",
  "candidate (test/preflight.sh's own candidate universe) is enrolled or\n",
  "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n",
  "targets exist, every entry is reachable by a selector, no two entries\n",
  "share a `name`, and every entry's `cost` and `tiers` are well formed.\n",
  "Exits nonzero on any violation. It checks the SHAPE of `tiers`, not\n",
  "whether it agrees with the workflows — that is\n",
  "test/diff_compiler_tier_drift.sh, which reads the workflow YAML.\n", "\n",
  "`gate ci` regenerates the marked GENERATED region in\n",
  ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n",
  "the registry's [[shard]] rows and every entry's `shard` field. Run it\n",
  "via `make gen-ci`.\n", "\n",
  "  --check            ci: compare only — compute the generated text and\n",
  "                     compare it IN MEMORY to the file on disk, writing\n",
  "                     nothing. Exit 0 when they agree, 1 with the first\n",
  "                     differing line when they do not. This is the drift\n",
  "                     check; regenerating first would heal an uncommitted\n",
  "                     hand-edit before any diff could see it, and diffing\n",
  "                     the whole file would also fire on an edit OUTSIDE\n",
  "                     the generated region.\n", "\n",
  "The named-gate steps in soundness/wasm are NOT\n",
  "generated — the registry cannot say which job runs which (see the\n",
  "`gate ci` section of compiler/tools/gate_cmd.mdk).\n", "\n",
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
  "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n", "\n",
  "`gate reach <changed-path>...` is the QUEUE's project scoping (#2179):\n",
  "which projects must run their gates for an entry touching those paths.\n",
  "A path under <project>/ selects that project, plus every project whose\n",
  "medaka.toml [dependencies] reaches it, plus the owning project of every\n",
  "gate whose `corpus` names a selected project. An empty list, a compiler/\n",
  "or stdlib/ path, and any path no project directory claims all FAIL OPEN\n",
  "to every project: this command never answers `nothing`.\n", "\n",
  "`gate budget` is #2180's governor: text-only, no build. Reds when (a) a\n",
  "schedulable gate has no cost baseline entry, (b) a gate's measured cost\n",
  "has eaten into the tolerance-adjusted timeout its declared `cost` class\n",
  "implies, or (c) the projected pole/floor (the same number `gate balance\n",
  "--check` derives) exceeds S-4's budget. Any violation may be accepted on\n",
  "purpose with a `Gate-Budget-Override: <token>` trailer on the commit\n",
  "message (there is no PR body in a merge_group run) — the failing gate\n",
  "prints the exact trailer to paste.\n", "\n",
  "  --commit-message <text>  budget: the commit message to scan for\n",
  "                     `Gate-Budget-Override:` trailers. Omit for none.\n"
]

-- Parsed `gate list` argv.
data ListArgs = ListArgs {
  json : Bool,
  shards : Bool,
  registry : Option String,
  selectors : List String,
}

-- S-3 (#2355): every subcommand's argv walk and its C2 unrecognized-flag
-- sentence now come from `stdlib/args.mdk` — `unknownFlagMessage` is the
-- ONE writer of that sentence tree-wide.  `args.mdk`'s own missing-value
-- wording ("<flag> requires a value") is uniform and NOT what this file has
-- always said; `missingValueOverride` below rewrites it back to the
-- pre-existing bespoke text verbatim, per verb, deliberately not normalized
-- this slice.
missingValueOverride : ArgSpec -> List (String, String) -> String -> String
missingValueOverride _ [] msg = msg
missingValueOverride sp ((flg, custom) :: rest) msg =
  if msg == missingValueMessage sp flg then
    custom
  else
    missingValueOverride sp rest msg

-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob.
listArgSpec : ArgSpec
listArgSpec =
  withStrictDash
    (spec "gate list" [
      switch ["--json"] "emit machine-readable JSON",
      switch ["--shards"] "print each entry's shard placement",
      value ["--registry"] "PATH" "override the gate registry path",
    ])

listMissingValue : List (String, String)
listMissingValue = [("--registry", "medaka gate list: --registry needs a path")]

parseListArgs : List String -> Result String ListArgs
parseListArgs argv = match parseArgs listArgSpec argv
  Err m => Err (missingValueOverride listArgSpec listMissingValue m)
  Ok a => Ok ListArgs {
    json = flag "--json" a,
    shards = flag "--shards" a,
    registry = flagValue "--registry" a,
    selectors = a.positionals,
  }

parseSelectors : List String -> List Selector -> Result String (List Selector)
parseSelectors [] acc = Ok (reverseSels acc [])
parseSelectors (t :: ts) acc = match parseSelector t
  Err m => Err m
  Ok s => parseSelectors ts (s :: acc)

reverseSels : List Selector -> List Selector -> List Selector
reverseSels [] acc = acc
reverseSels (s :: ss) acc = reverseSels ss (s :: acc)

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
listOutput argv = match parseListArgs argv
  Err m => Err m
  Ok a => match parseSelectors a.selectors []
    Err m => Err "medaka gate list: \{m}"
    Ok sels =>
      let path = registryPath a.registry
      match readFile path
        Err m => Err "medaka gate list: cannot read registry: \{m}"
        Ok src =>
          if a.shards then
            shardsOutput a.json a.selectors src
          else match parseRegistry src
            Err m => Err "medaka gate list: \{m}"
            Ok gates =>
              selectionOutput a.json a.selectors (selectGates sels gates) path

-- `--shards` lists the MATRIX ROWS, which selectors do not range over — a
-- selector is a per-gate predicate, and silently ignoring one here would let
-- `list --shards area:eval` look like it had filtered something.
shardsOutput : Bool -> List String -> String -> Result String String
shardsOutput isJson tokens src
  | not (isEmptyStrs tokens) =
    Err
      "medaka gate list: --shards takes no selectors (got: \{joinSpace tokens})"
  | otherwise = match parseShards src
    Err m => Err "medaka gate list: \{m}"
    Ok shs =>
      if isJson then
        Ok (renderShardsJson shs ++ "\n")
      else
        Ok (renderShards shs)

-- A selector that selects nothing is a HARD ERROR (see the module header).
selectionOutput : Bool ->
  List String ->
  List Gate ->
  String ->
  Result String String
selectionOutput _ tokens [] path
  | isEmptyStrs tokens = Err "medaka gate list: \{path} contains no gates"
  | otherwise = Err "medaka gate list: no gates match: \{joinSpace tokens}"
selectionOutput isJson _ (g :: gs) _ =
  if isJson then
    Ok (renderJson (g :: gs) ++ "\n")
  else
    Ok (renderNames (g :: gs))

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
joinSpace (x :: []) = x
joinSpace (x :: xs) = "\{x} \{joinSpace xs}"

{- | `medaka gate <sub> …`. -}
export
runGateCmd : List String -> <IO> Unit
runGateCmd [] =
  emit
    (Err
      "usage: medaka gate <list|run|verify|explain|reach|ci|balance|budget> [<selector>...] [--json]")
runGateCmd ("list" :: rest) = emit (listOutput rest)
runGateCmd ("run" :: rest) = runRunCmdBody rest
runGateCmd ("verify" :: rest) = verifyCmdBody rest
runGateCmd ("explain" :: rest) = explainCmdBody rest
runGateCmd ("reach" :: rest) = reachCmdBody rest
runGateCmd ("ci" :: rest) = ciCmdBody rest
runGateCmd ("balance" :: rest) = balCmdBody rest
runGateCmd ("budget" :: rest) = budgetCmdBody rest
runGateCmd (sub :: _) =
  emit
    (Err
      "medaka gate: unknown subcommand '\{sub}' (expected: list, run, verify, explain, reach, ci, balance, budget)")

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
public export data GateResult = GateResult {
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
data RunEnv = RunEnv {
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
  Ok (_, isDir, _, mt) =>
    if isDir then match listDir path
      Err _ => acc
      Ok names => newestMtimeEntries path names acc
    else if hasSourceExt path && mt > acc then
      mt
    else
      acc

newestMtimeEntries : String -> List String -> Float -> <IO> Float
newestMtimeEntries _ [] acc = acc
newestMtimeEntries dir (n :: rest) acc =
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
selectedOracles (g :: gs) = g.oracles ++ selectedOracles gs

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
scrapedOraclesIn scriptPath = match (runCommand "grep" [
  "-ohE", "test/bin/[a-z_0-9]+", scriptPath
])
  Err _ => []
  Ok (_, out, _) => map stripBinPrefix (filterList nonBlankLine (splitNl out))

nonBlankLine : String -> Bool
nonBlankLine s = stringTrim s /= ""

scrapedOracles : String -> List Gate -> <IO> List String
scrapedOracles _ [] = []
scrapedOracles root (g :: gs) =
  scrapedOraclesIn "\{root}/\{g.run}" ++ scrapedOracles root gs

-- MISSING is not stale — the gate's own "oracle not built" exit-2 owns that
-- case and says so in its own words.
staleOf : String -> Float -> List String -> <IO> List String
staleOf _ _ [] = []
staleOf root newest (o :: os) =
  let rest = staleOf root newest os
  match statFile "\{root}/test/bin/\{o}"
    Err _ => rest
    Ok (_, _, _, mt) => if mt < newest then o :: rest else rest

indentedNames : List String -> List String
indentedNames [] = []
indentedNames (o :: os) = "  \{o}" :: indentedNames os

staleBannerLines : List String -> List String
staleBannerLines [] = []
staleBannerLines (o :: os) =
  "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one \{o}"
    :: staleBannerLines os

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
      ]
      ++ staleBannerLines stale
      ++ [
        "",
        "(Override with NO_STALE_CHECK=1, --no-stale-check, or CI=1 only if you",
        " know exactly why.  This check is skipped in CI on purpose — see the",
        " comment above staleOf.)",
        "════════════════════════════════════════════════════════════════════",
        ""
      ])

-- run_gates.sh's `[ -z "${VAR:-}" ]`: SET-BUT-EMPTY counts as unset.
envSet : String -> <IO> Bool
envSet name = envOr name "" /= ""

staleRefusal : Bool -> String -> List Gate -> <IO> Option String
staleRefusal True _ _ = None
staleRefusal False root gs =
  if envSet "CI" || envSet "NO_STALE_CHECK" then
    None
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
  l :: _ => l

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
  if not (fileExists script) then
    spawnFailure
      g
      script
      "gate script not found (registry `run` field): \{g.run}"
      0.0
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
  | r.timedOut =
    "TIMEOUT \{r.name}  (exit \{intToString r.exitCode} after \{intToString (msOf r)}ms)\n"
  | r.exitCode == 0 = "PASS  \{r.name}  (\{intToString (msOf r)}ms)\n"
  | otherwise =
    "FAIL  \{r.name}  (exit \{intToString r.exitCode}, \{intToString (msOf r)}ms)\n"

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
runGatesLoop env (g :: gs) acc =
  let r = runOneGate env g
  let _ = putStr (resultLine r)
  let _ = flushStdout ()
  runGatesLoop env gs (r :: acc)

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
  if k <= n then
    s
  else
    let cs = stringToChars s
    stringSlice (afterNewlines cs 0 (arrayLength cs) (k - n)) (stringLength s) s

failureDetail : GateResult -> String
failureDetail r =
  let hdr =
    "\n───── \{r.name} — \{r.shell} \{r.script} (exit \{intToString r.exitCode}) ─────\n"
  let o =
    if stringTrim r.out == "" then
      "  (stdout: empty)\n"
    else
      "  ── stdout ──\n\{tailLines 200 r.out}\n"
  let e =
    if stringTrim r.err == "" then
      "  (stderr: empty)\n"
    else
      "  ── stderr ──\n\{tailLines 200 r.err}\n"
  "\{hdr}\{o}\{e}"

failureDetails : List GateResult -> String
failureDetails [] = ""
failureDetails (r :: rs)
  | gateOk r = failureDetails rs
  | otherwise = failureDetail r ++ failureDetails rs

-- ── summary + report ────────────────────────────────────────────────────────

countOk : List GateResult -> Int
countOk [] = 0
countOk (r :: rs) = (if gateOk r then 1 else 0) + countOk rs

failingNames : List GateResult -> List String
failingNames [] = []
failingNames (r :: rs)
  | gateOk r = failingNames rs
  | otherwise = r.name :: failingNames rs

resultJson : GateResult -> Json
resultJson r = jObject [
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
runReportJson jobs rs =
  stringify
    (jObject [
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
dryLines env (g :: gs) = dryLine env g ++ dryLines env gs

-- ── the `run` subcommand ────────────────────────────────────────────────────

data RunArgs = RunArgs {
  registry : Option String,
  selectors : List String,
  dryRun : Bool,
  json : Bool,
  report : Option String,
  timeoutSecs : Int,
  jobs : Int,
  noStaleCheck : Bool,
}

-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob.
runArgSpec : ArgSpec
runArgSpec =
  withStrictDash
    (spec "gate run" [
      switch ["--dry-run"] "print what would run, without running it",
      switch ["--json"] "emit the machine-readable timing report",
      switch ["--no-stale-check"] "skip the stale-oracle refusal",
      value ["--registry"] "PATH" "override the gate registry path",
      value ["--report"] "PATH" "write the timing report here",
      value ["--timeout"] "N" "per-gate timeout, in seconds",
      value
        ["--jobs"]
        "N"
        "worker count (reported only; gates run sequentially)",
    ])

runMissingValue : List (String, String)
runMissingValue = [
  ("--registry", "medaka gate run: --registry needs a path"),
  ("--report", "medaka gate run: --report needs a path"),
  ("--timeout", "medaka gate run: --timeout needs a number of seconds"),
  ("--jobs", "medaka gate run: --jobs needs a number"),
]

-- `--timeout`/`--jobs` stay plain `value` flags (not `args.mdk`'s `intValue`)
-- so the pre-existing bespoke invalid-integer wording survives untouched —
-- `intValue`'s own sentence ("expected an integer, got 'x'") is not one of
-- this slice's six C2 sites and is not licensed to normalize.
runTimeout : Args -> Result String Int
runTimeout a = match flagValue "--timeout" a
  None => Ok 0
  Some v => match parseDecChecked v
    None =>
      Err
        "medaka gate run: --timeout needs a whole number of seconds, got '\{v}'"
    Some n => Ok n

runJobs : Args -> Result String Int
runJobs a = match flagValue "--jobs" a
  None => Ok 1
  Some v => match parseDecChecked v
    None => Err "medaka gate run: --jobs needs a whole number, got '\{v}'"
    Some n => Ok n

parseRunArgs : List String -> Result String RunArgs
parseRunArgs argv = match parseArgs runArgSpec argv
  Err m => Err (missingValueOverride runArgSpec runMissingValue m)
  Ok a => match runTimeout a
    Err m => Err m
    Ok timeoutSecs =>
      map
        (jobs => RunArgs {
          registry = flagValue "--registry" a,
          selectors = a.positionals,
          dryRun = flag "--dry-run" a,
          json = flag "--json" a,
          report = flagValue "--report" a,
          timeoutSecs = timeoutSecs,
          jobs = jobs,
          noStaleCheck = flag "--no-stale-check" a,
        })
        (runJobs a)

-- The selection half, shared with `list`: read the registry, apply the
-- selectors, and treat a zero-gate selection as a HARD ERROR.  A mistyped
-- pattern that silently selects nothing is how a shard certifies coverage of a
-- gate that never ran (test/run_gates.sh:181).
selectFor : String ->
  List String ->
  List Selector ->
  String ->
  Result String (List Gate)
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
  let _ = if a.json then putStr (runReportJson a.jobs rs ++ "\n")
  let _ = if a.json then () else putStr (failureDetails rs)
  let _ = if a.json then () else putStr (summaryLine a.jobs rs)
  let bad = failingNames rs
  let _ =
    if a.json || isEmptyStrs bad then
      ()
    else
      putStr "FAILING: \{joinSpace bad}\n"
  if isEmptyStrs bad && wrote then exit 0 else exit 1

runSelected : RunArgs -> List Gate -> <IO> Unit
runSelected a gs =
  let env = runEnvFor a
  if a.dryRun then
    putStr (dryLines env gs)
  else match staleRefusal a.noStaleCheck env.root gs
    Some banner =>
      let _ = ePutStr banner
      exit 1
    None => finishRun a (runGatesLoop env gs [])

runRunCmdBody : List String -> <IO> Unit
runRunCmdBody argv = match parseRunArgs argv
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
gitLsFilesSh root args = match (runCommand
  "git"
  (["-C", root] ++ args ++ ["*.sh"]))
  Err e => Err "git ls-files failed to run: \{e}"
  Ok (0, out, _) => Ok (filterList nonBlank (splitNl out))
  Ok (code, _, err) => Err (gitExitMsg code (stringTrim err))

gateCandidates : String -> <IO> Result String (List String)
gateCandidates root = match gitLsFilesSh root ["ls-files"]
  Err m => Err m
  Ok tracked =>
    map
      (untracked => sortUniqS (tracked ++ untracked))
      (gitLsFilesSh root ["ls-files", "-o", "--exclude-standard"])

-- test/CI-COVERAGE-TOOLS.txt: one non-comment, non-blank line per excluded
-- tool, keyed by its FIRST whitespace-separated token (repo-relative path,
-- no `.sh`) — the same `awk 'NF { print $1 }'` preflight.sh runs.
liveLine : String -> Bool
liveLine l = nonBlank l && not (startsWith "#" (stringTrim l))

firstToken : String -> String
firstToken l = firstNonBlankTok (splitOnChar ' ' l)

firstNonBlankTok : List String -> String
firstNonBlankTok [] = ""
firstNonBlankTok (x :: xs) = if nonBlank x then x else firstNonBlankTok xs

toolNames : String -> <IO> List String
toolNames root = match readFile (joinPath root "test/CI-COVERAGE-TOOLS.txt")
  Err _ => []
  Ok src =>
    filterList nonBlank (map firstToken (filterList liveLine (splitNl src)))

stripSh : String -> String
stripSh p = if endsWith ".sh" p then stringSlice 0 (stringLength p - 3) p else p

allRuns : List Gate -> List String
allRuns [] = []
allRuns (g :: gs) = g.run :: allRuns gs

-- Check 1: every candidate is enrolled (its path is some entry's `run`) or
-- excluded (its path minus `.sh` is in test/CI-COVERAGE-TOOLS.txt).
unenrolledViolations : List String -> List String -> List String -> List String
unenrolledViolations _ _ [] = []
unenrolledViolations tools runs (c :: cs)
  | contains (stripSh c) tools = unenrolledViolations tools runs cs
  | contains c runs = unenrolledViolations tools runs cs
  | otherwise =
    "unenrolled: \{c}  (not a `run` in test/gates.toml, not listed in test/CI-COVERAGE-TOOLS.txt)"
      :: unenrolledViolations tools runs cs

-- Check 2: every entry's `run` target exists on disk (S-1/S-2's decision:
-- `run` is already the resolved relative path — a plain file-exists check,
-- not a re-glob against run_gates.sh's two-glob rule).
runTargetViolations : String -> List Gate -> <IO> List String
runTargetViolations _ [] = []
runTargetViolations root (g :: gs) =
  let rest = runTargetViolations root gs
  if fileExists "\{root}/\{g.run}" then
    rest
  else
    "\{g.name}: run target does not exist: \{g.run}" :: rest

-- Check 3: every non-empty oracle name is one of build_oracles.sh's own
-- ENTRIES (via its `--list` mode — no clang/libgc needed, builds nothing).
knownOracles : String -> <IO> List String
knownOracles root = match (runCommand "sh" [
  "\{root}/test/build_oracles.sh",
  "--list",
])
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
oracleNamesMissing known gname (o :: os)
  | contains o known || contains o foreignOracles =
    oracleNamesMissing known gname os
  | otherwise =
    "\{gname}: oracle not known to `test/build_oracles.sh --list` (nor the wasm-foreign set): \{o}"
      :: oracleNamesMissing known gname os

oracleTargetViolations : List String -> List Gate -> List String
oracleTargetViolations _ [] = []
oracleTargetViolations known (g :: gs) =
  oracleNamesMissing known g.name g.oracles ++ oracleTargetViolations known gs

-- Check 4: every entry is reachable by at least one selector.  See the block
-- comment above for why this is near-vacuous under today's schema, and the
-- one shape (a `:` in `name`) that is not.
anyNamed : String -> List Gate -> Bool
anyNamed _ [] = False
anyNamed n (g :: gs) = g.name == n || anyNamed n gs

reachabilityFor : List Gate -> Gate -> List String
reachabilityFor all g = match parseSelector g.name
  Err m => [
    "\{g.name}: its own name is not a valid bare selector (\{m}) — reachable only via an explicit `name:\{g.name}`, not the bare CLI form",
  ]
  Ok sel =>
    if anyNamed g.name (selectGates [sel] all) then
      []
    else
      [
        "\{g.name}: `name:\{g.name}` does not select this entry (registry/selector bug)",
      ]

reachabilityViolations : List Gate -> List Gate -> List String
reachabilityViolations _ [] = []
reachabilityViolations all (g :: gs) =
  reachabilityFor all g ++ reachabilityViolations all gs

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
corpusDirsMissing root gname (c :: cs) =
  let rest = corpusDirsMissing root gname cs
  if dirExists (joinPath root c) then
    rest
  else
    "\{gname}: corpus directory does not exist: \{c}" :: rest

corpusTargetViolations : String -> List Gate -> <IO> List String
corpusTargetViolations _ [] = []
corpusTargetViolations root (g :: gs) =
  corpusDirsMissing root g.name g.corpus ++ corpusTargetViolations root gs

-- Check 6 (#2199): entry `name`s are UNIQUE.  Two entries sharing a name were
-- merely redundant while the registry only described gates; with `shard` on
-- the entry they are a GENERATION HAZARD — "which matrix row does `foo` go
-- in" stops having one answer, and the generator would have to pick, silently.
-- Nothing else catches it: `run` targets, oracles and corpora would all still
-- exist, and check 4's reachability is satisfied by EITHER twin.
gateNames : List Gate -> List String
gateNames [] = []
gateNames (g :: gs) = g.name :: gateNames gs

countName : String -> List Gate -> Int
countName _ [] = 0
countName n (g :: gs) = (if g.name == n then 1 else 0) + countName n gs

dupNameFrom : List Gate -> List String -> List String
dupNameFrom _ [] = []
dupNameFrom gates (n :: ns) =
  let k = countName n gates
  let rest = dupNameFrom gates ns
  if k > 1 then
    "\{n}: \{intToString k} entries share this name — a gate's shard row must not be ambiguous"
      :: rest
  else
    rest

duplicateNameViolations : List Gate -> List String
duplicateNameViolations gates = dupNameFrom gates (sortUniqS (gateNames gates))

-- Check 7 (#2204): every `name` — a gate's and a `[[shard]]` row's — is inside
-- a CONSERVATIVE CHARSET.
--
-- ⚠️ A name is not just an identifier here, it is INTERPOLATED INTO TWO
-- LANGUAGES it does not control.  `medaka gate ci` emits a gate name into
-- ci.yml as a single-quoted word inside a double-quoted YAML scalar
-- (`pattern: "'a' 'b'"`), which the job then hands to `sh test/run_gates.sh`
-- as an UNQUOTED shell word; and a `[[shard]]` name is emitted as a bare YAML
-- scalar (`- name: tools`) that also becomes the required status-check context
-- `gates (<name>)`.  A `'`, `"`, `$`, backtick, `;`, `&`, `|`, `<`, `>`, `(`,
-- `)`, `#`, `:`, a space or a newline in a name therefore does not produce a
-- bad NAME — it produces a different WORKFLOW, or a different COMMAND, with no
-- error anywhere in this tool.  Nothing else in `verify` looks at a name's
-- spelling: check 4 (reachability) proves a name is selectable, and a name
-- full of metacharacters is perfectly selectable.
--
-- The allowed set is `[A-Za-z0-9_./]`, first character alphanumeric or `_`.
-- DERIVED, not chosen: it is exactly the set the whole committed registry
-- already uses (`grep '^name = "' test/gates.toml | tr -d 'A-Za-z0-9_./'`
-- yields nothing), so it forbids only spellings nothing has ever needed.  `/`
-- is in because out-of-`test/` gates are named by path (`pds/test/repo_vectors`);
-- `-` is out because a leading one reads as a flag to every consumer, and no
-- name uses one.
nameCharOk : String -> Bool
nameCharOk c
  | c >= "a" && c <= "z" = True
  | c >= "A" && c <= "Z" = True
  | c >= "0" && c <= "9" = True
  | c == "_" = True
  | c == "." = True
  | c == "/" = True
  | otherwise = False

nameLeadOk : String -> Bool
nameLeadOk c
  | c == "." = False
  | c == "/" = False
  | otherwise = nameCharOk c

nameCharsOk : String -> Int -> Int -> Bool
nameCharsOk s i n
  | i >= n = True
  | nameCharOk (stringSlice i (i + 1) s) = nameCharsOk s (i + 1) n
  | otherwise = False

-- The first character outside the set, as `<char>` at 1-based position — the
-- message has to name WHICH byte, or the reader is left eyeballing a string
-- whose whole problem is that it contains something invisible.
firstBadChar : String -> Int -> Int -> String
firstBadChar s i n
  | i >= n = "(none)"
  | not (nameCharOk (stringSlice i (i + 1) s)) =
    "'\{stringSlice i (i + 1) s}' at position \{intToString (i + 1)}"
  | otherwise = firstBadChar s (i + 1) n

unsafeName : String -> String -> List String
unsafeName kind n
  | n == "" = [
    "(empty): a \{kind} name is empty — it cannot be selected, quoted or generated",
  ]
  | not (nameLeadOk (stringSlice 0 1 n)) =
    ["\{n}: \{kind} name must start with a letter, a digit or '_'"]
  | not (nameCharsOk n 0 (stringLength n)) = [
    "\{n}: \{kind} name contains \{firstBadChar n 0 (stringLength n)} — allowed characters are letters, digits, '_', '.' and '/' (a name is emitted into ci.yml and re-read as an unquoted shell word)",
  ]
  | otherwise = []

unsafeGateNames : List Gate -> List String
unsafeGateNames [] = []
unsafeGateNames (g :: gs) = unsafeName "gate" g.name ++ unsafeGateNames gs

unsafeShardNames : List Shard -> List String
unsafeShardNames [] = []
unsafeShardNames (s :: ss) =
  unsafeName "shard row" s.name ++ unsafeShardNames ss

unsafeNameViolations : List Gate -> List Shard -> List String
unsafeNameViolations gates shs = unsafeGateNames gates ++ unsafeShardNames shs

-- Check 8 (FR-5, review finding S2-3): every entry's `cost` is one of the
-- THREE classes `timeoutFor` actually matches (`cheap`/`medium`/`heavy`).
-- `cost` is a required TOML string with no enum check at parse time, so a
-- typo (`cost = "banana"`) used to fall through `timeoutFor`'s `otherwise =
-- 900` fallback silently — same kill timeout as `medium`, but with no
-- registry-level signal that anything was wrong, and `gate budget` clause
-- (b) grading it against `medium`'s ceiling without ever having declared it.
costClassOk : String -> Bool
costClassOk c = c == "cheap" || c == "medium" || c == "heavy"

invalidCostViolations : List Gate -> List String
invalidCostViolations [] = []
invalidCostViolations (g :: gs)
  | costClassOk g.cost = invalidCostViolations gs
  | otherwise =
    "\{g.name}: cost '\{g.cost}' is not one of cheap/medium/heavy"
      :: invalidCostViolations gs

-- Check 9 (S-tier-is-data, #2181): every entry's `tiers` is a well-formed set of
-- RUN TOKENS.  The old `tier : String` had no enum check either, but a bad
-- value there could only mis-answer a `tier:` selector; a bad value HERE also
-- mis-answers `test/diff_compiler_tier_drift.sh`, which compares these tokens
-- against the workflows.  A drift gate whose declared side can be arbitrary
-- text is a drift gate that reports on typos rather than on drift.
tierNameOk : String -> Bool
tierNameOk t = t == "merge" || t == "nightly" || t == "ondemand"

-- Whether a run token carries a `/` at all — the presence of a mode
-- separator, not the mode text itself. `modePartOf` alone cannot answer this:
-- it returns `""` both for "no `/`" (`"merge"`) and for "`/` present, empty
-- suffix" (`"ondemand/"`), so a caller that only tests `modePartOf tok /= ""`
-- cannot tell the two apart (F10, #2181 review finding). A token is longer
-- than its own tier part exactly when a `/` follows the tier.
hasModeSep : String -> Bool
hasModeSep tok = stringLength tok > stringLength (tierPartOf tok)

-- `ondemand` means "nothing invokes this automatically".  It cannot carry a
-- mode (there is no invocation for a mode to differ from) and cannot sit beside
-- another tier (a gate that runs somewhere is not on demand) — both would be
-- claims the drift gate must then reconcile with an empty derivation.
tierTokenErrors : String -> String -> List String
tierTokenErrors gname tok
  | not (tierNameOk (tierPartOf tok)) = [
    "\{gname}: run token '\{tok}' — tier '\{tierPartOf tok}' is not one of merge/nightly/ondemand",
  ]
  | tierPartOf tok == "ondemand" && hasModeSep tok = [
    "\{gname}: run token '\{tok}' — 'ondemand' cannot carry a mode; nothing invokes the gate, so there is no invocation for a mode to differ from",
  ]
  | otherwise = []

tierTokensErrors : String -> List String -> List String
tierTokensErrors _ [] = []
tierTokensErrors gname (t :: ts) =
  tierTokenErrors gname t ++ tierTokensErrors gname ts

hasOndemand : List String -> Bool
hasOndemand [] = False
hasOndemand (t :: ts) = tierPartOf t == "ondemand" || hasOndemand ts

-- Sorted-and-unique in one predicate: strictly ascending.  Sorted keeps a
-- registry diff readable as a change of fact; unique stops one run being
-- declared twice, which would let a duplicate stand in for a missing tier.
strictlyAscending : List String -> Bool
strictlyAscending [] = True
strictlyAscending (_ :: []) = True
strictlyAscending (a :: b :: rest) = a < b && strictlyAscending (b :: rest)

invalidTiersViolations : List Gate -> List String
invalidTiersViolations [] = []
invalidTiersViolations (g :: gs) =
  gateTiersErrors g ++ invalidTiersViolations gs

gateTiersErrors : Gate -> List String
gateTiersErrors g
  | isEmptyStrs g.tiers = [
    "\{g.name}: tiers is empty — every gate has at least one run; a gate nothing invokes is tiers = [\"ondemand\"]",
  ]
  | not (strictlyAscending g.tiers) =
    ["\{g.name}: tiers \{joinWith " " g.tiers} is not sorted and unique"]
  | hasOndemand g.tiers && listLen g.tiers > 1 = [
    "\{g.name}: tiers \{joinWith " " g.tiers} mixes 'ondemand' with a real run — 'ondemand' means nothing invokes this gate, so it appears alone or not at all",
  ]
  | otherwise = tierTokensErrors g.name g.tiers

-- ── assembling and rendering the nine classes ───────────────────────────────

verifyClasses : String ->
  List Gate ->
  List Shard ->
  <IO> Result String (List (String, List String))
verifyClasses root gates shs = match gateCandidates root
  Err m => Err "could not enumerate gate candidates: \{m}"
  Ok cands =>
    let tools = toolNames root
    let runs = allRuns gates
    let known = knownOracles root
    Ok [
      ("unenrolled gate scripts", unenrolledViolations tools runs cands),
      ("missing run targets", runTargetViolations root gates),
      ("missing oracle targets", oracleTargetViolations known gates),
      ("missing corpus targets", corpusTargetViolations root gates),
      ("unreachable entries", reachabilityViolations gates gates),
      ("duplicate entry names", duplicateNameViolations gates),
      ("unsafe entry names", unsafeNameViolations gates shs),
      ("invalid cost class", invalidCostViolations gates),
      ("invalid tiers", invalidTiersViolations gates),
    ]

renderClass : (String, List String) -> String
renderClass (title, []) = "OK    \{title}: 0\n"
renderClass (title, vs) =
  let names = joinNl (indentedNames vs)
  "FAIL  \{title}: \{intToString (listLen vs)}\n\{names}\n"

renderClasses : List (String, List String) -> String
renderClasses [] = ""
renderClasses (c :: cs) = renderClass c ++ renderClasses cs

totalViolations : List (String, List String) -> Int
totalViolations [] = 0
totalViolations ((_, vs) :: cs) = listLen vs + totalViolations cs

verifyOutput : String -> List Gate -> List Shard -> <IO> Result String String
verifyOutput root gates shs = match verifyClasses root gates shs
  Err m => Err "medaka gate verify: \{m}\n"
  Ok classes =>
    let n = totalViolations classes
    let body = renderClasses classes
    if n == 0 then
      Ok
        (body
          ++ "medaka gate verify: OK — \{intToString (listLen gates)} entries, 0 violations.\n")
    else
      Err
        (body
          ++ "medaka gate verify: FAIL — \{intToString n} violation(s) across \{intToString (listLen gates)} entries.\n")

-- `verify` prints its body even on failure — the message-carrying `Err`
-- string above IS the violation report, not a one-liner, so `emit`'s ordinary
-- "print to stderr and exit 1" path is exactly what we want here too.
data VerifyArgs = VerifyArgs { registry : Option String }

-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob.
verifyArgSpec : ArgSpec
verifyArgSpec =
  withStrictDash
    (spec "gate verify" [
      value ["--registry"] "PATH" "override the gate registry path",
    ])

verifyMissingValue : List (String, String)
verifyMissingValue =
  [("--registry", "medaka gate verify: --registry needs a path")]

-- `verify` takes no positionals at all (unlike `list`/`run`/`reach`) — a
-- leftover token, dash-shaped or not, was always rejected the same way as an
-- unclaimed flag, so a stray positional gets the SAME `unknownFlagMessage`
-- rendering `args.mdk`'s own unclaimed-token path would have produced.
parseVerifyArgs : List String -> Result String VerifyArgs
parseVerifyArgs argv = match parseArgs verifyArgSpec argv
  Err m => Err (missingValueOverride verifyArgSpec verifyMissingValue m)
  Ok a => match a.positionals
    [] => Ok VerifyArgs { registry = flagValue "--registry" a }
    p :: _ => Err (unknownFlagMessage verifyArgSpec p)

verifyCmdBody : List String -> <IO> Unit
verifyCmdBody argv = match parseVerifyArgs argv
  Err m => emit (Err m)
  Ok a =>
    let path = registryPath a.registry
    match readFile path
      Err m => emit (Err "medaka gate verify: cannot read registry: \{m}")
      Ok src => match parseRegistry src
        Err m => emit (Err "medaka gate verify: \{m}")
        Ok gates => match parseShards src
          Err m => emit (Err "medaka gate verify: \{m}")
          Ok shs =>
            let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
            emit (verifyOutput root gates shs)

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
blastHit (p :: ps) path = if globMatch p path then Some p else blastHit ps path

{- | Layer 1b: is this path PROSE?  The same allowlist
   `.github/workflows/ci.yml`'s `detect` job applies (its `nondoc` case), kept
   in the same order for the same reason its own comment gives: `test/**` is
   NEVER prose (it holds functional goldens), while `docs/spec/SYNTAX.md` and
   `docs/guide/*.md` are executable documentation.

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
  | startsWith "docs/guide/" p && endsWith ".md" p = False
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
sourceMatches path (s :: ss)
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
corpusMatches path (c :: cs)
  | underDir c path = "corpus:\{c}" :: corpusMatches path cs
  | otherwise = corpusMatches path cs

targetedReasons : String -> Gate -> List String
targetedReasons path g =
  sourceMatches path g.sources ++ corpusMatches path g.corpus

explainPathHits : String -> List Gate -> List (Gate, List String)
explainPathHits _ [] = []
explainPathHits path (g :: gs) =
  let rs = targetedReasons path g
  let rest = explainPathHits path gs
  if isEmptyStrs rs then rest else (g, rs) :: rest

hasWholeTree : List String -> Bool
hasWholeTree [] = False
hasWholeTree (s :: ss) = wholeTreeGlob s || hasWholeTree ss

wholeTreeGates : List Gate -> List Gate
wholeTreeGates [] = []
wholeTreeGates (g :: gs)
  | hasWholeTree g.sources = g :: wholeTreeGates gs
  | otherwise = wholeTreeGates gs

-- ── the selector-token half (S-4): a bare token that IS a field value ───────

fieldHit : String -> Bool -> List String
fieldHit _ False = []
fieldHit field True = [field]

matchedFields : String -> Gate -> List String
matchedFields tok g =
  fieldHit "run" (tok == g.run)
    ++ fieldHit "name" (tok == g.name)
    ++ fieldHit "area" (tok == g.area)
    ++ fieldHit "project" (tok == g.project)
    ++ fieldHit "tiers" (anyEqStr tok g.tiers)

-- `tiers` is a list, so a bare token hits it when it IS one of the run tokens —
-- exact, not glob: `explain` is answering "is this word also a field value?",
-- and a glob answer there would claim a hit the user did not ask for.
anyEqStr : String -> List String -> Bool
anyEqStr _ [] = False
anyEqStr tok (x :: xs) = tok == x || anyEqStr tok xs

explainMatches : String -> List Gate -> List (Gate, List String)
explainMatches _ [] = []
explainMatches tok (g :: gs) =
  let fs = matchedFields tok g
  let rest = explainMatches tok gs
  if isEmptyStrs fs then rest else (g, fs) :: rest

isEmptyHits : List (Gate, List String) -> Bool
isEmptyHits [] = True
isEmptyHits _ = False

renderGateLines : List (Gate, List String) -> String
renderGateLines [] = ""
renderGateLines ((g, rs) :: hs) =
  "  GATE      \{g.name}  (\{joinWith ", " rs})\n" ++ renderGateLines hs

renderWholeTree : List Gate -> String
renderWholeTree [] = ""
renderWholeTree (g :: gs) =
  "  GATE      \{g.name}  (sources:*, whole-tree)\n" ++ renderWholeTree gs

renderTokenLines : List (Gate, List String) -> String
renderTokenLines [] = ""
renderTokenLines ((g, fs) :: hs) =
  "  TOKEN     \{g.name}  (selector field: \{joinWith ", " fs})\n"
    ++ renderTokenLines hs

tokenSection : String -> List Gate -> String
tokenSection tok gates =
  let hits = explainMatches tok gates
  if isEmptyHits hits then "" else renderTokenLines hits

blastNote : String
blastNote =
  "  (registry-level policy, not per-entry data: a blast-radius path runs the\n"
    ++ "   WHOLE suite whatever any entry's sources say — design doc §2.)\n"

failOpenNote : String
failOpenNote =
  "  (no entry's sources/corpus claims this path and it is not prose, so the\n"
    ++ "   selection FAILS OPEN to the whole suite — never a silent empty set.)\n"

proseNote : String
proseNote =
  "  (prose: no entry claims it and it cannot widen the suite — ci.yml's own\n"
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
        (if isProsePath path then
            "  UNMAPPED  \{path}\n" ++ proseNote
          else
            "  UNMAPPED  \{path}\n  FULL      unmatched-non-prose:\{path}\n"
              ++ failOpenNote)
          ++ wt
          ++ tok
      else
        renderGateLines hits ++ wt ++ tok

data ExplainArgs = ExplainArgs {
  registry : Option String,
  path : Option String,
  prose : Bool,
}

-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob.
explainArgSpec : ArgSpec
explainArgSpec =
  withStrictDash
    (spec "gate explain" [
      value ["--registry"] "PATH" "override the gate registry path",
      switch ["--prose"] "print only the PROSE/NONDOC verdict",
    ])

explainMissingValue : List (String, String)
explainMissingValue =
  [("--registry", "medaka gate explain: --registry needs a path")]

parseExplainArgs : List String -> Result String ExplainArgs
parseExplainArgs argv = match parseArgs explainArgSpec argv
  Err m => Err (missingValueOverride explainArgSpec explainMissingValue m)
  Ok a => match a.positionals
    [] => Ok ExplainArgs {
      registry = flagValue "--registry" a,
      path = None,
      prose = flag "--prose" a,
    }
    [p] => Ok ExplainArgs {
      registry = flagValue "--registry" a,
      path = Some p,
      prose = flag "--prose" a,
    }
    _ => Err "medaka gate explain: expected exactly one <path> argument"

explainCmdBody : List String -> <IO> Unit
explainCmdBody argv = match parseExplainArgs argv
  Err m => emit (Err m)
  Ok a => match a.path
    None =>
      emit
        (Err "usage: medaka gate explain <path> [--prose] [--registry <path>]")
    Some tok =>
      if a.prose then
        putStr (proseVerdict tok)
      else
        let path = registryPath a.registry
        match readFile path
          Err m => emit (Err "medaka gate explain: cannot read registry: \{m}")
          Ok src => match parseRegistry src
            Err m => emit (Err "medaka gate explain: \{m}")
            Ok gates => putStr (explainOutput tok gates)

-- ── `gate reach` — which PROJECTS must a queue entry run gates for? ─────────
--
-- (#2179, epic #2182.)  `medaka gate reach <changed-path>...` answers the
-- question the merge queue asks before it narrows anything: given the paths a
-- queue entry touches, WHICH PROJECTS' gates have to run?  Three rules, and the
-- fourth line below is the one that keeps the answer safe:
--
--   1. DIRECT — a path under `<project>/` selects that project.
--   2. REVERSE DEPENDENCY — a selected project pulls in every project that
--      DECLARES it, transitively.  The edges come from the manifests'
--      `[dependencies]` sections, read with the LOADER's own `readDeps`, which
--      is the only path a cross-project import resolves through
--      (`driver/loader.mdk`: `resolveDepFile` consults declared dep names and
--      nothing else; its `findInRoots` fallback ranges only over the entry's own
--      dir, its project root, and the stdlib root).  NEVER from import names:
--      `stdlib/byteparser.mdk` and the project `byteparser/` share a module
--      name, so a `grep '^import byteparser'` graph invents
--      `gzip -> byteparser`, `pds -> byteparser`, `sqlite -> byteparser` and
--      `byteparser -> byteparser` edges no manifest declares.  Dep VALUES are
--      compared realpath-canonicalized rather than matched by the manifest KEY,
--      so `parsec = "../parsec"` and `pc = "../parsec"` are ONE edge —
--      `loader.revLookupRoot` draws exactly the same line for the same reason.
--   3. CORPUS — a gate whose `corpus` names a PROJECT reads that project's tree
--      as its fixture corpus (`wasm/diff_gzip` -> `gzip`, `wasm/diff_sqlite` ->
--      `sqlite`, both owned by `compiler`).  Those are reverse edges no manifest
--      can show, so a selected corpus project pulls its gates' OWNING project
--      back in.  Rules 2 and 3 are run to a JOINT fixpoint, not in two passes:
--      the corpus rule can select a project the dependency rule then widens
--      from, and stopping after one round of each would be a narrowing whose
--      correctness depended on today's edge set.
--
-- 🚨 FAIL-OPEN IS THE POINT.  An EMPTY changed-path list, a path under
-- `compiler/` or `stdlib/`, and any path no project directory claims all select
-- the WHOLE universe.  A narrowing derivation that answers "nothing" on input it
-- does not understand certifies coverage that never ran — the same reason
-- `explain`'s layer 1 fails open (design doc §2), and the reason `compiler` is
-- deliberately NOT a direct-hit directory here: a compiler change is precisely
-- the change that can break every project's gates at once.

{- | The project that owns the compiler's own gates.  Named rather than
   inlined because `reach` treats it as a SENTINEL, not as a directory: see the
   fail-open note above. -}
compilerProject : String
compilerProject = "compiler"

-- The non-compiler projects whose directory contains `path`.
directHits : List String -> String -> List String
directHits [] _ = []
directHits (p :: ps) path
  | p == compilerProject = directHits ps path
  | underDir p path = p :: directHits ps path
  | otherwise = directHits ps path

concatHits : List String -> List String -> List String
concatHits _ [] = []
concatHits univ (path :: rest) = directHits univ path ++ concatHits univ rest

allHit : List String -> List String -> Bool
allHit _ [] = True
allHit univ (path :: rest) =
  not (isEmptyStrs (directHits univ path)) && allHit univ rest

{- | Must the answer for this changed-path list be the WHOLE project universe?
   True for an empty list, and true as soon as ONE path lies under no project
   directory — a `compiler/` or `stdlib/` path, a `test/` path, a doc, an
   absolute path, an empty string.

   > reachIsFailOpen ["a", "b"] []
   True

   > reachIsFailOpen ["a", "b"] ["a/src/x.mdk"]
   False

   > reachIsFailOpen ["a", "b", "compiler"] ["compiler/frontend/lexer.mdk"]
   True

   > reachIsFailOpen ["a", "b"] ["README.md"]
   True

   > reachIsFailOpen ["a", "b"] ["a/src/x.mdk", ""]
   True

   > reachIsFailOpen ["a", "b"] ["/etc/passwd"]
   True -}
export
reachIsFailOpen : List String -> List String -> Bool
reachIsFailOpen univ paths
  | isEmptyStrs paths = True
  | otherwise = not (allHit univ paths)

anyIn : List String -> List String -> Bool
anyIn [] _ = False
anyIn (x :: xs) sel = contains x sel || anyIn xs sel

-- One relation step: every LHS whose RHS meets the current selection.  Used for
-- BOTH edge kinds — the manifest edges (project -> its declared deps) and the
-- corpus edges (gate-owning project -> the projects in its `corpus`) are the
-- same shape and the same rule, so they share one traversal.
edgeAdds : List (String, List String) -> List String -> List String
edgeAdds [] _ = []
edgeAdds ((lhs, rhs) :: rest) sel
  | anyIn rhs sel = lhs :: edgeAdds rest sel
  | otherwise = edgeAdds rest sel

-- Joint fixpoint over both edge relations.  `fuel` bounds the walk by the size
-- of the universe: the selection is a subset of it and grows by at least one on
-- every non-final round, so it cannot loop even on a cyclic edge set.
closeGo : Int ->
  List (String, List String) ->
  List (String, List String) ->
  List String ->
  List String
closeGo fuel deps ces sel
  | fuel <= 0 = sel
  | otherwise =
    let nxt = sortUniqS (sel ++ edgeAdds deps sel ++ edgeAdds ces sel)
    if listLen nxt == listLen sel then sel else closeGo (fuel - 1) deps ces nxt

{- | The projects a queue entry touching `paths` must run gates for: `univ` is
   the project universe (every `project` value in the registry), `deps` the
   manifest edges (project -> the projects it declares), `ces` the registry's
   corpus edges (gate-owning project -> the projects its `corpus` names).
   Sorted and deduplicated.

   The one real manifest edge in the committed tree is `sqlite -> parsec`, so a
   parsec change must run sqlite's gates too — and sqlite is a corpus project, so
   `compiler` comes back in behind it:

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [("sqlite", ["parsec"])] [("compiler", ["gzip", "sqlite"])] ["parsec/src/x.mdk"]
   ["compiler", "parsec", "sqlite"]

   A project nothing declares selects only itself, plus the owner of any gate
   whose corpus IS that project:

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [("sqlite", ["parsec"])] [("compiler", ["gzip", "sqlite"])] ["gzip/src/x.mdk"]
   ["compiler", "gzip"]

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [("sqlite", ["parsec"])] [] ["gzip/src/x.mdk"]
   ["gzip"]

   Fail-open: an empty list, a `compiler/` path, an unmapped path and malformed
   input all select the whole universe rather than erroring or selecting nothing.

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [] [] []
   ["compiler", "gzip", "parsec", "sqlite"]

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [] [] ["compiler/frontend/lexer.mdk"]
   ["compiler", "gzip", "parsec", "sqlite"]

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [] [] ["README.md"]
   ["compiler", "gzip", "parsec", "sqlite"]

   > reachProjects ["compiler", "gzip", "parsec", "sqlite"] [] [] ["gzip/src/x.mdk", ""]
   ["compiler", "gzip", "parsec", "sqlite"] -}
export
reachProjects : List String ->
  List (String, List String) ->
  List (String, List String) ->
  List String ->
  List String
reachProjects univ deps ces paths =
  let all = sortUniqS univ
  if reachIsFailOpen all paths then
    all
  else
    closeGo (listLen all + 1) deps ces (sortUniqS (concatHits all paths))

-- ── `gate reach`: building the two edge sets from the tree ──────────────────

{- | Every `project` value in the registry, sorted and deduplicated.  DERIVED,
   never listed: a project enrolled tomorrow appears here the moment its floor
   gate does ([W-PROJECT-BY-MANIFEST] makes that enrolment mandatory). -}
export
projectUniverse : List Gate -> List String
projectUniverse gs = sortUniqS (map (g => g.project) gs)

{- | The registry's corpus edges as (owning project, the corpus values that name
   a PROJECT).  A `corpus` naming a fixture directory (`test/…`) is not a project
   edge and is dropped; a gate left with none contributes no edge at all. -}
export
corpusProjectEdges : List String -> List Gate -> List (String, List String)
corpusProjectEdges _ [] = []
corpusProjectEdges univ (g :: gs) =
  let cs = filterList (c => contains c univ) g.corpus
  let rest = corpusProjectEdges univ gs
  if isEmptyStrs cs then rest else (g.project, cs) :: rest

-- realpath-compare one manifest-resolved dep root against each project dir, so
-- `sqlite/../parsec` and `parsec` are recognised as the same directory.
projectForRoot : String -> List String -> String -> <IO> Option String
projectForRoot _ [] _ = None
projectForRoot root (q :: qs) dr =
  if canonicalizePath (joinPath root q) == canonicalizePath dr then
    Some q
  else
    projectForRoot root qs dr

depRootsOf : List (String, String) -> List String
depRootsOf [] = []
depRootsOf ((_, r) :: rest) = r :: depRootsOf rest

depProjectsGo : String -> List String -> List String -> <IO> List String
depProjectsGo _ _ [] = []
depProjectsGo root univ (dr :: rest) = match projectForRoot root univ dr
  Some q => q :: depProjectsGo root univ rest
  None => depProjectsGo root univ rest

-- The projects `p`'s own medaka.toml declares in `[dependencies]`.  A dep
-- pointing outside the project universe (a vendored path, say) is dropped: it
-- has no gates of its own to run.
depProjectsOf : String -> List String -> String -> <IO> List String
depProjectsOf root univ p =
  sortUniqS (depProjectsGo root univ (depRootsOf (readDeps (joinPath root p))))

{- | The manifest dependency edges over the project universe. -}
projectDepEdges : String ->
  List String ->
  List String ->
  <IO> List (String, List String)
projectDepEdges _ _ [] = []
projectDepEdges root univ (p :: ps) =
  let ds = depProjectsOf root univ p
  let rest = projectDepEdges root univ ps
  if isEmptyStrs ds then rest else (p, ds) :: rest

renderProjects : List String -> String
renderProjects [] = ""
renderProjects (p :: ps) = "\{p}\n" ++ renderProjects ps

{- | `--json`: the selection, whether it FAILED OPEN, and the changed-path list
   it was derived from.  `failOpen` is in the payload because the text rendering
   deliberately prints names and nothing else (it is read by `grep` and by a
   shell `for`), and a consumer that cannot tell a derived answer from a
   widened one cannot tell a narrowing bug from a safe default. -}
reachJson : Bool -> List String -> List String -> String
reachJson failOpen paths projects =
  stringify
      (jObject [
        ("projects", jArray (map JString projects)),
        ("failOpen", JBool failOpen),
        ("changed", jArray (map JString paths)),
      ])
    ++ "\n"

data ReachArgs = ReachArgs {
  registry : Option String,
  root : Option String,
  json : Bool,
  pathsFrom : Option String,
  paths : List String,
}

-- `--` ends flag parsing, so ANY string can be handed over as a path: a changed
-- path the classifier does not understand must fail OPEN (below), and that
-- promise would be worth nothing if a leading `-` could turn it into exit 1.
-- `args.mdk`'s `TrailingAfterSeparator` is exactly this policy: it consumes
-- the first bare `--` and hands everything after it back verbatim in `rest`.
-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob. Composes with
-- `withTrailing` below — the `--` escape hatch still hands anything after it
-- to `rest` verbatim, dash-shaped or not; strictDash only governs tokens
-- BEFORE the separator.
reachArgSpec : ArgSpec
reachArgSpec =
  withStrictDash
    (withTrailing
      TrailingAfterSeparator
      (spec "gate reach" [
        value ["--registry"] "PATH" "override the gate registry path",
        value ["--root"] "PATH" "override MEDAKA_ROOT",
        value ["--paths-from"] "PATH" "read changed paths from a file",
        switch ["--json"] "emit JSON",
      ]))

-- `reach` is the tree's only verb whose unrecognized-flag sentence carries an
-- extra hint after the shared `(known: …)` tail — appended here, on top of
-- the one-writer `unknownFlagMessage` rendering, not baked into it.  Since
-- `reach` declares no `OneOf`/`IntValue` flags, `invalidValueMessage` can
-- never fire, so any `Err` that survives the missing-value rewrites below
-- must be the unrecognized-flag one.
parseReachArgs : List String -> Result String ReachArgs
parseReachArgs argv = match parseArgs reachArgSpec argv
  Err m => Err (reachRewriteErr m)
  Ok a => Ok ReachArgs {
    registry = flagValue "--registry" a,
    root = flagValue "--root" a,
    json = flag "--json" a,
    pathsFrom = flagValue "--paths-from" a,
    paths = a.positionals ++ a.rest,
  }

reachRewriteErr : String -> String
reachRewriteErr msg
  | msg == missingValueMessage reachArgSpec "--registry" =
    "medaka gate reach: --registry needs a path"
  | msg == missingValueMessage reachArgSpec "--root" =
    "medaka gate reach: --root needs a path"
  | msg == missingValueMessage reachArgSpec "--paths-from" =
    "medaka gate reach: --paths-from needs a path"
  | otherwise =
    -- The hint lands INSIDE the `(known: …)` parenthetical, matching the
    -- pre-migration wording exactly — splice before `unknownFlagMessage`'s
    -- trailing `)` rather than appending after it.
    stringSlice 0 (stringLength msg - 1) msg
      ++ "; use `--` before a path starting with '-')"

-- Blank lines are dropped from a `--paths-from` FILE and nowhere else.  `git
-- diff --name-only` ends in a newline, so its last line is always empty, and
-- classifying that would make every invocation fail open and the command
-- useless.  An empty POSITIONAL argument is NOT dropped: that one the caller
-- actually passed, and input this command cannot classify must widen, not vanish.
nonBlankPaths : List String -> List String
nonBlankPaths xs = filterList nonBlank xs

-- The changed-path list.  An unreadable `--paths-from` file FAILS OPEN (an
-- empty list selects the whole universe) rather than dying: this command sits
-- in front of a narrowing decision, so every unknown must widen.
reachPaths : ReachArgs -> <IO> List String
reachPaths a = match a.pathsFrom
  None => a.paths
  Some f => match readFile f
    Err m =>
      let _ =
        ePutStrLn
          "medaka gate reach: cannot read \{f} (\{m}) — failing open to every project"
      []
    Ok src => a.paths ++ nonBlankPaths (splitNl src)

reachRoot : Option String -> <IO> String
reachRoot (Some p) = p
reachRoot None = envOr "MEDAKA_ROOT" defaultMedakaRoot

reachCmdBody : List String -> <IO> Unit
reachCmdBody argv = match parseReachArgs argv
  Err m => emit (Err m)
  Ok a =>
    let rpath = registryPath a.registry
    match readFile rpath
      Err m => emit (Err "medaka gate reach: cannot read registry: \{m}")
      Ok src => match parseRegistry src
        Err m => emit (Err "medaka gate reach: \{m}")
        Ok gates =>
          let univ = projectUniverse gates
          let paths = reachPaths a
          let ces = corpusProjectEdges univ gates
          let deps = projectDepEdges (reachRoot a.root) univ univ
          let sel = reachProjects univ deps ces paths
          if a.json then
            putStr (reachJson (reachIsFailOpen univ paths) paths sel)
          else
            putStr (renderProjects sel)

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
-- idempotent.  The drift check is `medaka gate ci --check`, which compares in
-- memory and writes nothing — NOT `make gen-ci && git diff --exit-code`, which
-- heals an uncommitted hand-edit inside the region before the diff can see it
-- and also fires on an edit outside the region.
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
-- `project = "compiler"`, `tiers = ["merge"]`, `cost = "cheap"`,
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
ciMatrixBegin =
  "          # GENERATED:BEGIN gates-matrix — `make gen-ci` (medaka gate ci) from test/gates.toml. DO NOT EDIT BY HAND."

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
dropTrailBlank (x :: [])
  | x == "" = []
  | otherwise = [x]
dropTrailBlank (x :: xs) = x :: dropTrailBlank xs

-- `'a' 'b' 'c'` — the inner single-quoted token list of a row's pattern.
ciQuotedNames : List Gate -> String
ciQuotedNames [] = ""
ciQuotedNames (g :: []) = "'\{g.name}'"
ciQuotedNames (g :: gs) = "'\{g.name}' \{ciQuotedNames gs}"

-- The gates of one row, in registry order.
ciShardGates : String -> List Gate -> List Gate
ciShardGates nm gs = filterList (g => (g : Gate).shard == nm) gs

-- A `"1"` matrix key is emitted ONLY when the option is on — ci.yml omits the
-- key entirely when off, and that asymmetry is the file's convention, not the
-- registry's (`shardBool` insists the boolean is present in the registry for
-- exactly this reason).
ciOptLine : String -> Bool -> List String
ciOptLine _ False = []
ciOptLine key True = ["            \{key}: \"1\""]

ciRowLines : List Gate -> List String -> Shard -> List String
ciRowLines rowGates prose sh =
  ["          - name: \{sh.name}"]
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
  [] =>
    Err
      "medaka gate ci: shard '\{sh.name}' has no gates in the registry — a row with an empty pattern fails its own shard in CI"
  rowGates => match readFile (joinPath root sh.rationale)
    Err m =>
      Err
        "medaka gate ci: shard '\{sh.name}': cannot read rationale \{sh.rationale}: \{m}"
    Ok src => Ok (ciRowLines rowGates (dropTrailBlank (splitNl src)) sh)

ciRowsLoop : String ->
  List Gate ->
  List Shard ->
  List String ->
  <IO> Result String (List String)
ciRowsLoop _ _ [] acc = Ok (reverseL acc)
ciRowsLoop root gates (sh :: shs) acc = match ciOneRow root gates sh
  Err m => Err m
  Ok ls => ciRowsLoop root gates shs (reverseL ls ++ acc)

-- Is every gate's `shard` either a declared row or the `other-job` sentinel?
-- A typo'd shard name would otherwise drop that gate from the matrix SILENTLY
-- — the gate stays in the registry, answers `gate list`, and runs nowhere.
ciKnownShard : List Shard -> String -> Bool
ciKnownShard _ "other-job" = True
ciKnownShard [] _ = False
ciKnownShard (sh :: shs) nm = sh.name == nm || ciKnownShard shs nm

ciUnknownShards : List Shard -> List Gate -> List String
ciUnknownShards _ [] = []
ciUnknownShards shs (g :: gs)
  | ciKnownShard shs g.shard = ciUnknownShards shs gs
  | otherwise = "\{g.name} (shard '\{g.shard}')" :: ciUnknownShards shs gs

-- ── Splicing the region ─────────────────────────────────────────────────────

ciCountLine : String -> List String -> Int
ciCountLine _ [] = 0
ciCountLine want (l :: ls)
  | l == want = 1 + ciCountLine want ls
  | otherwise = ciCountLine want ls

ciIndexOf : String -> List String -> Int -> Int
ciIndexOf _ [] _ = -1
ciIndexOf want (l :: ls) i
  | l == want = i
  | otherwise = ciIndexOf want ls (i + 1)

-- Copy from the END marker onward, verbatim.
ciAfterEnd : List String -> List String
ciAfterEnd [] = []
ciAfterEnd (l :: ls)
  | l == ciMatrixEnd = l :: ls
  | otherwise = ciAfterEnd ls

ciSpliceGo : List String -> List String -> List String
ciSpliceGo _ [] = []
ciSpliceGo gen (l :: ls)
  | l == ciMatrixBegin = l :: gen ++ ciAfterEnd ls
  | otherwise = l :: ciSpliceGo gen ls

-- The markers must appear EXACTLY once each, in order.  Anything else is a
-- malformed file, and splicing it would quietly drop or duplicate the region.
ciSplice : List String -> List String -> Result String (List String)
ciSplice gen src
  | ciCountLine ciMatrixBegin src /= 1 =
    Err
      "medaka gate ci: \{ciWorkflowRel} must contain exactly one BEGIN marker line (found \{intToString (ciCountLine ciMatrixBegin src)}):\n\{ciMatrixBegin}"
  | ciCountLine ciMatrixEnd src /= 1 =
    Err
      "medaka gate ci: \{ciWorkflowRel} must contain exactly one END marker line (found \{intToString (ciCountLine ciMatrixEnd src)}):\n\{ciMatrixEnd}"
  | ciIndexOf ciMatrixEnd src 0 < ciIndexOf ciMatrixBegin src 0 =
    Err
      "medaka gate ci: \{ciWorkflowRel}: the END marker precedes the BEGIN marker"
  | otherwise = Ok (ciSpliceGo gen src)

-- ── The command ─────────────────────────────────────────────────────────────

data CiArgs = CiArgs {
  registry : Option String,
  workflow : Option String,
  check : Bool,
}

parseCiArgs : List String -> CiArgs -> Result String CiArgs
parseCiArgs [] acc = Ok acc
parseCiArgs ("--registry" :: p :: rest) acc =
  parseCiArgs rest CiArgs { acc | registry = Some p }
parseCiArgs ("--registry" :: []) _ =
  Err "medaka gate ci: --registry needs a path"
parseCiArgs ("--workflow" :: p :: rest) acc =
  parseCiArgs rest CiArgs { acc | workflow = Some p }
parseCiArgs ("--workflow" :: []) _ =
  Err "medaka gate ci: --workflow needs a path"
parseCiArgs ("--check" :: rest) acc =
  parseCiArgs rest CiArgs { acc | check = True }
parseCiArgs (a :: _) _ = Err "medaka gate ci: unexpected argument: \{a}"

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
      bad =>
        Err
          "medaka gate ci: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace bad}"

-- Write only on a real change: an unconditional write would touch the file's
-- mtime on every no-op run, and `make gen-ci` is meant to be free to re-run.
ciWrite : String -> String -> String -> <IO> Unit
ciWrite wfPath wfSrc out
  | out == wfSrc = putStr "medaka gate ci: \{wfPath} already up to date\n"
  | otherwise = match writeFile wfPath out
    Err m => emit (Err "medaka gate ci: cannot write \{wfPath}: \{m}")
    Ok _ => putStr "medaka gate ci: regenerated the gates matrix in \{wfPath}\n"

-- The first line at which the on-disk file and the regenerated text part
-- company, rendered for a human.  `ciNewText` copies everything before the
-- BEGIN marker and everything from the END marker onward VERBATIM
-- (`ciSpliceGo`/`ciAfterEnd`), so any line this reports is necessarily inside
-- the generated region: an edit outside it appears identically on both sides
-- and can never be the first difference.
ciDiffAt : List String -> List String -> Int -> String
ciDiffAt [] [] _ = "  (the two texts differ only in trailing newline)"
ciDiffAt [] (g :: _) n =
  "  line \{intToString n}:\n    on disk:   <end of file>\n    generated: \{g}"
ciDiffAt (d :: _) [] n =
  "  line \{intToString n}:\n    on disk:   \{d}\n    generated: <end of file>"
ciDiffAt (d :: ds) (g :: gs) n
  | d == g = ciDiffAt ds gs (n + 1)
  | otherwise =
    "  line \{intToString n}:\n    on disk:   \{d}\n    generated: \{g}"

-- `--check`: the SAME comparison `ciWrite` makes, with no write and no shell
-- out to `git diff`.  Two reasons it is not "regenerate, then `git diff`":
-- writing first HEALS an uncommitted hand-edit inside the region before the
-- diff can see it (the check then passes having destroyed the edit), and
-- `git diff` on the whole file also fires on an uncommitted edit OUTSIDE the
-- region, which this check by construction does not (see `ciDiffAt`).
ciCheckResult : String -> String -> String -> Result String String
ciCheckResult wfPath wfSrc out
  | out == wfSrc = Ok "medaka gate ci: \{wfPath} already up to date\n"
  | otherwise =
    Err
      (stringConcat [
        "medaka gate ci: \{wfPath}: the generated gates-matrix region does not\n",
        "match what test/gates.toml generates.  First difference:\n",
        ciDiffAt (splitNl wfSrc) (splitNl out) 1,
        "\nRun 'make gen-ci' and commit the result.\n",
      ])

ciCmdBody : List String -> <IO> Unit
ciCmdBody argv = match (parseCiArgs argv CiArgs {
  registry = None,
  workflow = None,
  check = False,
})
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
          Ok out =>
            if a.check then
              emit (ciCheckResult wfPath wfSrc out)
            else
              ciWrite wfPath wfSrc out

-- ── `gate balance` (#2178) ──────────────────────────────────────────────────
--
-- `medaka gate balance` CHOOSES each gate's `shard` row, from the registry's
-- own constraints plus S-1's measured cost baseline
-- (`test/gate_cost_baseline.json`), instead of the hand-assignment the header
-- of `test/gates.toml` describes as "HAND-ASSIGNED DATA, NOT A DERIVED
-- OUTPUT".  After this command the eight row NAMES are still fixed (they are
-- required status-check contexts, `gates (<name>)`, so they are not free to
-- change) — only which gates land in each is computed.
--
-- ⚠️ THE ASSIGNMENT LIVES IN `test/gates.toml`, by TARGETED LINE REPLACEMENT.
-- The alternative — a second, generated file that overrides the registry's
-- `shard` — was rejected: `gate ci`, `gate list`, `gate verify`,
-- `diff_compiler_ci_shard_coverage.sh` and `test/preflight.sh` all read
-- `shard` from this file today, and a second source of truth is only safe if
-- EVERY one of them learns the override rule.  Any that does not schedules
-- from stale data silently, which is [W-THIRD-CONSUMER] with extra steps; and
-- a `shard` field left present-but-vestigial is a lie that greps true.  So
-- there stays exactly one place a row assignment is written, and this command
-- rewrites it.
--
-- Only the `shard = "…"` lines move.  `stdlib/toml.mdk` is a PARSER with no
-- serializer, so round-tripping 230 hand-written entries through it is not
-- available and would be a formatting-drift trap if it were (`balSplice`).
--
-- ── The objective ───────────────────────────────────────────────────────────
--
-- The `gates` job's wall-clock is its SLOWEST row (the pole); its billed
-- runner-time is `rows × pole`.  So the waste a balancer can actually remove
-- is the gap between the pole and the best pole any assignment could reach —
-- the FLOOR — and the enforced statement is `pole / floor` (`balFactorMilli`).
--
-- 🚨 IT USED TO BE `pole / median`, AND THAT METRIC WAS PERVERSE IN BOTH
-- DIRECTIONS (S-4, #2216).  Its denominator is a property of the SUITE, not of
-- the packing, so it moved for reasons the balancer neither caused nor could
-- repair:
--
--   * The pole is one indivisible gate.  A 16-20% slowdown in that ONE gate
--     raises the pole while the median stands still, so `ci-gen-drift` — a
--     REQUIRED check — goes red with no repair available to anyone who did not
--     write that gate.  `dominating_gate.toml` was that case as a fixture, and
--     it was committed as a REFUSAL.
--   * Worse, the same metric reds when the suite gets FASTER.  Speed up every
--     non-pole gate by 4× and the median falls while the pole does not, so
--     `pole / median` RISES.  `nonpole_speedup.toml` is that measured: an
--     optimally packed 7-gate suite scoring 3.333 against a target of 1.250.
--
-- The floor is the ACHIEVABLE pole: the largest of three quantities, each of
-- which the pole provably cannot go below (`balFloor`) —
--
--   1. the most expensive single gate (gates are indivisible, so whichever row
--      holds it has a makespan at least that big);
--   2. the heaviest CLOSED row's makespan (the packer moves nothing onto a
--      `full_cores` row or off it, so that row's load is fixed input);
--   3. the open gates' total work divided by the open rows' worker SLOTS — a
--      row's capacity is its recorded `rjobs` parallel workers, not one
--      (`balJobsFor`), so `sum(rjobs) × pole >= total work`.
--
-- So `pole / floor >= 1.000` always, it is 1.000 exactly when the packing is
-- optimal, and it moves ONLY when the packing changes: both perverse cases
-- above score 1.000 under it, and the classic LPT worst case
-- (`lpt_packing_gap.toml`) still scores 1.222 and is still refused.  It is a
-- budget and not a wish — `balance` and `balance --check` both FAIL when the
-- assignment they would emit misses it.
--
-- ⚠️ The floor is a LOWER BOUND, not always an achievable makespan: 500 + three
-- 300s over three rows floors at 500 and cannot finish before 600.  So a miss
-- can still be indivisibility rather than packing, and `balEnforce` keeps two
-- messages so a reader is never sent to "rebalance harder" when the answer is
-- "this gate has to get FASTER".
--
-- ⚠️ ONE VALID FLOOR TERM IS DELIBERATELY OMITTED: the wasm-constrained gates'
-- own work over the wasm rows' slots.  Leaving a valid term out makes the floor
-- SMALLER and the ratio LARGER, i.e. strictly stricter, so it cannot manufacture
-- a false green; add it if a wasm-only red ever turns out to be unrepairable.
--
-- ── A row's score is its MAKESPAN, and it predicts real wall clock ──────────
--
-- 🚨 THIS SECTION USED TO SAY THE OPPOSITE, AND THE OLD CLAIM WAS FALSE.  It
-- read "costs are RELATIVE, not predicted wall-clock", and justified scoring a
-- row by the SUM of its gates' medians on the grounds that the sum "is NOT
-- what CI will print for the row" but is still the right relative signal.  It
-- is not.  CI does not run a row's gates one after another: `test/run_gates.sh`
-- fans them out through an `xargs -P $JOBS` pool, so what CI prints for a row
-- is the MAKESPAN over `$JOBS` workers, and a sum over-states every row by
-- roughly `$JOBS`× — unevenly, because a row of one huge gate and a row of
-- many small ones do not shrink by the same factor under the same pool.  A
-- score that is wrong by a per-row-varying factor is not a relative signal
-- either; it is the pole being minimised on the wrong axis.
--
-- So a row's load here is the makespan of scheduling its gates onto `$JOBS`
-- worker buckets, longest-first, mirroring the pool: `balBucketAdd` puts each
-- gate on the least-loaded bucket and `rload` is the fullest bucket.  This is
-- an LPT simulation NESTED inside the LPT across rows (`balSortCands`), which
-- is why both take their candidates cost-descending.
--
-- ⚠️ `$JOBS` IS READ, NEVER ASSUMED.  `run_gates.sh` derives it from the
-- runner's core count (`(NCPU*3+2)/5`), so it is not one fixed number and no
-- literal here can stand in for it.  Since S-1 each row's own run records the
-- `jobs` it actually used, and `balJobsFor` reads that — see its own note for
-- what happens to a row that has never been recorded.
--
-- ⚠️ THE MODEL IS VALIDATED AGAINST SOMETHING OTHER THAN ITSELF.  S-1 also
-- records each row's `rowElapsedMs` — the row's real CI wall clock, spanning
-- the whole fan-out.  `balCalibLines` prints, per row, that recorded number
-- against this model's prediction for the COMMITTED assignment, and the
-- residual between them.  A model whose only evidence is its own arithmetic
-- would be unfalsifiable; this block is what makes it checkable by a reader.
-- Read the caveat in `balCalibLines` before reading the residuals: they are
-- only comparable while the committed assignment is still the one that ran.

-- One schedulable gate, joined with its measured cost.
data Cand = Cand {
  cname : String,
  crun : String,
  curRow : String,
  cms : Int,
  needsWasm : Bool,
}

-- One matrix row, with the load accumulated onto it so far.
--
-- `rload` is the row's MAKESPAN, not the sum of its gates: the fullest of its
-- `rjobs` worker buckets.  It is kept as a field rather than recomputed at
-- every read because `balPick` consults it once per candidate per row.
-- `rbuckets` always has exactly `rjobs` entries (`balJobsFor` guarantees
-- `rjobs >= 1`), and the two are only ever updated together, by `balAdd`.
data Row = Row {
  rname : String,
  rwasm : Bool,
  rclosed : Bool,
  rload : Int,
  rcount : Int,
  rjobs : Int,
  rbuckets : List Int,
}

-- One gate's outcome: where it goes, and where it came from.
data Place = Place { pname : String, pfrom : String, pto : String }

{- | The sentinel `shard` value for a gate some other workflow job schedules.
   These never enter the packing (derive the current count, don't trust one
   pinned here: `grep -c '^shard = "other-job"$' test/gates.toml` — it rots on
   every enrolment/removal): they never go through `test/run_gates.sh`, and so
   they structurally cannot appear in the cost baseline either.
   `diff_compiler_must_fail` is one of them — its INVERTED
   polarity ([G-MUST-FAIL]) is `compiler-soundness`'s business, and a matrix
   balancer must never so much as see it. -}
export
balOtherJob : String
balOtherJob = "other-job"

{- | The enforced `pole / floor` budget, in thousandths.  See "The objective"
   for what the floor is and why the denominator stopped being the median.

   1.125 IS DERIVED FROM A MEASUREMENT, NOT CHOSEN.  The arithmetic, in full,
   so a future reader can redo it rather than trust it:

     * The metric's own optimum is 1.000, by construction — `balFloor` is a
       lower bound on the pole, so the ratio cannot go below one and the whole
       budget is PACKING SLACK.  There is no achieved-value term to leave room
       for, which is exactly what the old `pole / median` ceiling had to do.

     * What the budget must absorb is therefore only re-ingest NOISE: the
       baseline's `medianMs` values move on every scheduled ingest, and both
       the pole and the floor are recomputed from them.  S-2 measured that
       noise out-of-sample rather than guessing at it — leave-one-run-out over
       the 3 runs in `runs[]`, across 202 of 202 schedulable gates: per-run
       errors -21.1% / -6.1% / -9.0%, mean |error| 12.0%, systematic bias
       -12.5% (the median is deliberately low-side robust —
       `gate_cost.packStat`).

       ⚠️ THOSE FIVE NUMBERS ARE ONE HISTORICAL MEASUREMENT, NOT A FIGURE THE
       TOOL RE-DERIVES.  They were taken on the baseline as it stood at S-2,
       by a `balOosBlock` that inferred each sample's run from its POSITION;
       FR-1 (#2222 review S0-1) showed that inference is unsound in general
       and replaced it with a recorded per-sample runId, so the block now
       reports "not derivable" on any baseline whose samples predate
       `sampleRuns` — which includes the one these numbers came from.  The
       budget below therefore stands on the S-2 measurement as a dated
       observation.  Re-derive it, and this constant with it, once enough
       attributed ingests have landed for `balOosBlock` to print a figure
       again.

     * Budget = 1 + max(mean |error|, |bias|) = 1 + max(0.120, 0.125) = 1.125.
       The LARGER of the two terms, because they are two ways of being wrong
       about the same prediction and a budget has to cover the worse one.

   ⚠️ THAT IS THE CONSERVATIVE DIRECTION, KNOWINGLY.  Much of the measured error
   is COMMON MODE — a run that is 12% slow is slow in the numerator and the
   denominator alike — and a common-mode factor cancels in a ratio, so 12.5% is
   an upper bound on the noise this metric can actually inherit, not an
   estimate of it.  Erring high is deliberate: the failure mode of a too-tight
   budget is a red `ci-gen-drift` with no repair available, which is the exact
   defect (#2216) this metric exists to remove.  Erring high costs only
   sensitivity to a packing that is bad by less than an eighth.

   ⚠️ IT IS STILL A REAL CONSTRAINT, WHICH IS WHY IT WAS NOT ROUNDED UP FURTHER.
   LPT's worst case is `4/3 - 1/(3m)` — 1.222 at three rows, 1.292 at the
   registry's eight — so a genuinely worst-case packing misses 1.125 and is
   refused.  `lpt_packing_gap.toml` pins that at 1.222.

   Achieved on the committed registry at the time this landed: 1.000 (pole
   482.2s = `diff_compiler_dict_semantics` alone, which is also the floor), so
   the full 12.5% is headroom and no re-ingest noise in that one gate can red
   it — under the retired metric the same gate's cost WAS the red. -}
balTargetMilli : Int
balTargetMilli = 1125

-- Hysteresis threshold, as a percentage of the pole. 🚨 It no longer decides
-- WHETHER a gate moves (S-4, #2178, see `balBandNote` below) — the emitted
-- assignment is always the derived target. It survives only as the REPORT's
-- account of whether a move was worth its churn: a projected pole gain of
-- this percentage or less is annotated "not reached" rather than "TAKEN",
-- so a one-millisecond drift in one gate's median is visibly noise, not a
-- claimed improvement, even though the target still moves it.
balMarginPct : Int
balMarginPct = 5

{- | The incumbent row's slack, as a percentage of the LPT pick's current row
   load.  See `balPickStable` for the mechanism, `balStays` for why the
   comparison is made before the gate is added rather than after, and
   `balTarget` for why reading the incumbent at all is sound.

   🚨 NOT `balMarginPct`, DELIBERATELY, AND THE TWO MUST NOT BE MERGED.  They
   are numbers in different units answering different questions:

     * `balMarginPct` is 5% OF THE POLE, and it grades the WHOLE assignment
       after the fact — "was this rebalance worth its churn?" — for the report.
     * this is a percentage OF ONE ROW'S LOAD at ONE placement step, and it
       decides a single gate's row.

   Folding them into one constant would mean one edit silently retunes both a
   scheduling decision and a report's wording, and it would make the report's
   "a move needs a pole gain of more than 5%" line read as if it described the
   packer, which is exactly the confusion S-4 of #2178 removed.

   HELD AT 5 ON A MEASUREMENT, NOT A GUESS.  Measured against the committed
   202-gate registry under three independent ±2% perturbation shapes (index
   parity, its opposite, and a name-hashed sign), counting gates whose derived
   `shard` moved: 89 / 128 / 127 without the preference, 0 / 4 / 0 with it, at
   an achieved pole identical to three significant figures in all three (the
   printed factor moved by at most 0.005, measured as pole/median, the metric
   S-4 of #2216 retired).  Table and method:
   `docs/ops/GATE-REGISTRY-DESIGN.md` §12.

   The pole is not free in general: a slack of p% lets a placement land on a row
   up to p% heavier than the lightest legal one.  It is exactly free on an
   UNPERTURBED input — the committed assignment IS the packer's output, so every
   incumbent already equals the pick and the preference never fires — which is
   why the cost only ever shows up on a re-ingest, and why `balStabLine` states
   the realised figure on every run rather than leaving it to this comment. -}
balStabPct : Int
balStabPct = 5

-- ── Quantizing noisy costs — TRIED AND MEASURED AWAY (S-4, #2178/#2207) ─────
--
-- 🚨 EVERY GATE IN THE COMMITTED BASELINE IS SCORED OFF AS FEW AS ONE OR TWO
-- SAMPLES.  `balSortCands`'s order and `balAdd`'s per-row makespan are both a
-- direct function of `Cand.cms`, so an ordinary re-ingest's measurement noise
-- (a slow runner, a GC pause, cache warmth) changes `cms` by a percent or
-- two and can flip which of two near-tied gates sorts first, or which row a
-- gate newly clears the least-loaded threshold for — moving the ASSIGNMENT
-- even though nothing about the SUITE changed. Measured on this baseline
-- perturbed by +/-2% per gate (alternating sign, deterministic — ordinary
-- jitter's rough magnitude): 113 of 202 gates' derived `shard` differed from
-- the unperturbed run.
--
-- The obvious fix is to quantize `medianMs` into a bucket before it becomes
-- `cms`, so two nearly-tied costs collapse to the same scheduling value.
-- THIS WAS TRIED, IN TWO SHAPES, AND MEASURED TO NOT WORK — recorded here so
-- the next reader does not re-attempt it blind:
--
--   (a) bucket width = a percentage of the value ITSELF (snap `ms` to the
--       nearest multiple of `5% of ms`). Measured WORSE than no bucketing:
--       188 of 202 bucketed values changed under the same perturbation,
--       because jittering `ms` also jitters the bucket width, so the grid
--       moves under the noise instead of absorbing it.
--
--   (b) a FIXED geometric grid (1ms, growing by a constant ratio) — immune
--       to (a)'s flaw, since the grid's boundaries do not depend on the
--       noisy reading. Swept the ratio at 3/5/8/10/15/20/30/50 percent
--       against the SAME 202-gate registry and TWO INDEPENDENT perturbation
--       seeds (opposite-parity sign assignment, plus a name-hashed wobble on
--       the second). Real shard-assignment churn (not bucketed-value churn)
--       was NON-MONOTONIC in the ratio and, at every ratio tried, was
--       sometimes BETTER and sometimes WORSE than doing nothing: seed 1 went
--       113 (unbucketed) -> {107, 89, 122, 117, 76, 74, 157, 151} across the
--       eight ratios; seed 2's own unbucketed number (71, different from
--       seed 1's because the two seeds are different perturbations) went to
--       78 at the ratio (20%) that looked best on seed 1. Two seeds, same
--       ratio, opposite direction of effect: a fix that helps or hurts
--       depending on which noise draw you happen to get is not damping
--       noise, it is fitting one.
--
-- The reason is structural, not a bad ratio choice: `balPick` places each
-- candidate on the row with STRICTLY the least CUMULATIVE load, across only
-- eight rows. Bucketing an individual gate's cost narrows that gate's OWN
-- tie window, but the quantity `balPick` actually compares — the running sum
-- of many gates' costs on each row — still drifts by the sum of many
-- individual snap-to-bucket roundings, and a handful of milliseconds is
-- routinely enough to flip which of eight rows is "least loaded" at a given
-- step. Once one placement flips, every later placement on that row's
-- history can cascade. Bucketing the INPUT does not control the quantity the
-- packer is actually sensitive to, so it cannot be the fix; a real
-- discussion of the LPT packer's sensitivity to cumulative-load ties is a
-- separate, larger question than this slice's cost-quantization mandate.
--
-- So the emitted assignment stays a pure function of the raw `medianMs` —
-- `cms` below is unchanged from before this note — and the honest response
-- to "ordinary noise moves gates" is Step 4's thin-evidence visibility
-- (`balThinLine`), not a damped score. The alternative (i) the contract also
-- named — widen the estimate for `samples < N` gates — was considered too,
-- and is moot the same way bucketing's target was: the committed baseline is
-- at a uniform sample count per gate right now (see `GateCost.samples`; as of
-- S-1-baseline-autoadvance that count is 3, capped at `maxSamples` = 9 as
-- fresh ingests land), so there is no under-sampled subset to widen.

-- A gate needs the Wasm arm when its toolchain names `wasm-tools` or a `node`
-- version.  Per the sprint contract §4.4, `sqlite3` and `valgrind` are
-- installed on EVERY row by ci.yml's "Setup medaka" step, so they constrain
-- nothing; `wasm-tools`/`node` is the only row-conditional toolchain, and
-- which rows offer it is read from `[[shard]]`'s `wasm_arm`, never assumed.
balNeedsWasm : List String -> Bool
balNeedsWasm [] = False
balNeedsWasm (t :: ts)
  | t == "wasm-tools" = True
  | startsWith "node" t = True
  | otherwise = balNeedsWasm ts

-- ── Building the candidate set ──────────────────────────────────────────────

-- Gates with no row for their `shard` value, as names.  A gate naming a row
-- that does not exist cannot be scheduled at all, and must not be silently
-- dropped from the packing (which would quietly REMOVE it from CI).
balUnknownRows : List Shard -> List Gate -> List String
balUnknownRows _ [] = []
balUnknownRows shs (g :: gs)
  | g.shard == balOtherJob = balUnknownRows shs gs
  | balHasRow g.shard shs = balUnknownRows shs gs
  | otherwise = g.name :: balUnknownRows shs gs

balHasRow : String -> List Shard -> Bool
balHasRow _ [] = False
balHasRow n (s :: ss)
  | s.name == n = True
  | otherwise = balHasRow n ss

-- Schedulable gates whose `run` script has no row in the cost baseline.
--
-- ⚠️ HARD ERROR, NEVER A ZERO.  A missing cost read as 0 does not make the
-- packing a little worse — it makes the gate free, so the packer piles it onto
-- whatever row is already lightest and the projection it prints is confidently
-- wrong.  `gate_cost.baselineKey` is the join key precisely because the
-- obvious join (on `name`) misses 53 of the 202 schedulable entries in
-- silence; this check is what makes any future drift in that key loud.
balUncosted : List GateCost -> List Gate -> List String
balUncosted _ [] = []
balUncosted base (g :: gs)
  | g.shard == balOtherJob = balUncosted base gs
  | otherwise = match costOf g.run base
    Some _ => balUncosted base gs
    None =>
      "\{g.name} (baseline key '\{baselineKey g.run}')" :: balUncosted base gs

balCands : List GateCost -> List Gate -> List Cand
balCands _ [] = []
balCands base (g :: gs)
  | g.shard == balOtherJob = balCands base gs
  | otherwise = match costOf g.run base
    None => balCands base gs
    Some ms =>
      Cand {
          cname = g.name,
          crun = g.run,
          curRow = g.shard,
          cms = ms,
          needsWasm = balNeedsWasm g.toolchain,
        }
        :: balCands base gs

-- ⚠️ A `full_cores` row is CLOSED, not merely preferred.
--
-- `engines` exists because `diff_compiler_engines` needs a whole runner to
-- itself; its row-mates are there because they share that need, and none of
-- that is a cost fact the packer can see.  So the packer neither moves a gate
-- OFF a full-cores row nor moves one ON — the row's membership is an input,
-- and the remaining rows are what it packs.
--
-- This is also what makes the target assignment a pure function of (registry
-- constraints, costs) and therefore a FIXED POINT: closing the row on the
-- `full_cores` flag rather than on "whatever is there now" means re-running
-- the balancer on its own output derives the same pin set, hence the same
-- target.  See `balTarget`.
balRows : List RunRecord -> List Shard -> List Row
balRows _ [] = []
balRows runs (s :: ss) =
  let j = balJobsFor s.name runs
  Row {
      rname = s.name,
      rwasm = s.wasmArm,
      rclosed = s.fullCores,
      rload = 0,
      rcount = 0,
      rjobs = j,
      rbuckets = balZeros j,
    }
    :: balRows runs ss

{- | The worker count to model this row's fan-out with: the `jobs` its own most
   recent recorded run actually used (S-1, #2208).

   ⚠️ NEVER A LITERAL, AND NEVER A GUESS DRESSED AS A MEASUREMENT.  `$JOBS` is
   `(NCPU*3+2)/5` on whatever runner CI gave the row, so it is a property of
   the run, not a constant this file may hold.

   Two fallbacks, in order, for a row the baseline has no `jobs` for:

     1. The most recent `jobs` recorded on ANY row.  Every row runs on the same
        `ubuntu-latest` runner class, so the worker count is a property of the
        runner and not of the row — borrowing a sibling's is a measurement, not
        an assumption, and it is what makes a NEWLY ADDED row modellable at all.

     2. Failing that (a baseline with no recorded `jobs` anywhere — every
        synthetic fixture, and any baseline ingested before S-1), 1: the row is
        modelled SERIALLY, which is exactly the sum this slice replaced.

   Fallback 2 is deliberately the conservative direction and not merely the
   convenient one.  Modelling a row with FEWER workers than it has OVER-states
   its makespan, so the packer moves work OFF it; over-stating `jobs` would
   under-state the makespan and pile work ON, which is the fail-open direction
   (`balUncosted`'s "a missing cost is not a cheap gate" argument, one axis
   over).  A fallback is still a fallback, so `balReport` names every row that
   used one rather than letting a serial row sit silently among honest ones.

   A hard refusal was considered and rejected: a brand-new `[[shard]]` row has
   no recorded run BY CONSTRUCTION, and refusing to balance until it has one
   would deadlock — its first run cannot happen until `ci.yml` schedules gates
   onto it, and nothing is scheduled onto it until the balancer runs.

   ⚠️ `parallel == Some False` OVERRIDES `jobs` entirely (F-2, #2178 review
   S3-3).  `run_gates.sh` hardcodes `parallel: true` today, so this is
   currently vacuous, but a future producer that ran a row's gates serially
   would have `jobs` describe a worker count the row never actually used —
   modelling it at that `jobs` would UNDER-state its makespan by roughly
   `jobs`×, the same fail-open direction fallback 2 above exists to avoid. A
   row recorded as non-parallel is modelled at 1 worker regardless of what
   `jobs` says. -}
balJobsFor : String -> List RunRecord -> Int
balJobsFor n runs = match latestRunForShard n runs
  Some r => match r.parallel
    Some False => 1
    _ => match r.jobs
      Some j if j >= 1 => j
      _ => balAnyJobs runs 1
  None => balAnyJobs runs 1

-- The latest `jobs` recorded on any row, in file order (the ingester appends,
-- so the last one wins), or the given default when no run records one.
balAnyJobs : List RunRecord -> Int -> Int
balAnyJobs [] acc = acc
balAnyJobs (r :: rs) acc = match r.jobs
  Some j if j >= 1 => balAnyJobs rs j
  _ => balAnyJobs rs acc

-- True when this row's worker count is borrowed or defaulted rather than its
-- own recorded measurement — what `balReport` annotates.
balJobsIsFallback : String -> List RunRecord -> Bool
balJobsIsFallback n runs = match latestRunForShard n runs
  Some r => match r.jobs
    Some j if j >= 1 => False
    _ => True
  None => True

balZeros : Int -> List Int
balZeros n
  | n <= 0 = []
  | otherwise = 0 :: balZeros (n - 1)

-- ── The packing ─────────────────────────────────────────────────────────────

-- Longest-processing-time first: the classic list-scheduling heuristic, and
-- the reason the pole lands on its floor here rather than merely near it —
-- the biggest gate is placed first, onto an empty row, so nothing can be
-- stacked on top of it afterwards except by a row that is still lighter.
--
-- Ties break on the gate NAME, so the output is a function of the inputs and
-- not of `gates.toml`'s line order.
candBefore : Cand -> Cand -> Bool
candBefore a b
  | a.cms /= b.cms = a.cms > b.cms
  | otherwise = a.cname < b.cname

balSortCands : List Cand -> List Cand
balSortCands [] = []
balSortCands (x :: []) = x :: []
balSortCands xs =
  let (l, r) = balHalve xs [] []
  balMergeCands (balSortCands l) (balSortCands r)

balHalve : List Cand -> List Cand -> List Cand -> (List Cand, List Cand)
balHalve [] a b = (a, b)
balHalve (x :: xs) a b = balHalve xs b (x :: a)

balMergeCands : List Cand -> List Cand -> List Cand
balMergeCands [] ys = ys
balMergeCands xs [] = xs
balMergeCands (x :: xs) (y :: ys)
  | candBefore x y = x :: balMergeCands xs (y :: ys)
  | otherwise = y :: balMergeCands (x :: xs) ys

-- The open row a gate should go on: the lightest row that can legally run it.
-- Scanning with a STRICT `<` keeps the first minimum, so an all-equal set of
-- rows resolves in `[[shard]]` order — deterministic, and stable as loads grow.
balPick : Cand -> List Row -> Option String
balPick c rs = balPickGo c rs None

balPickGo : Cand -> List Row -> Option Row -> Option String
balPickGo _ [] None = None
balPickGo _ [] (Some b) = Some b.rname
balPickGo c (r :: rs) best
  | r.rclosed = balPickGo c rs best
  | c.needsWasm && not r.rwasm = balPickGo c rs best
  | otherwise = match best
    None => balPickGo c rs (Some r)
    Some b =>
      if r.rload < b.rload then balPickGo c rs (Some r) else balPickGo c rs best

{- | The row a gate should go on, with the INCUMBENT row given a bounded
   preference over the LPT pick (S-3, #2218).

   🚨 READ `balBandNote` FIRST.  A near-identical-LOOKING mechanism shipped in
   #2178 and was REVERTED, and the difference between that one and this one is
   the whole reason this one is allowed to exist.  The reverted mechanism let
   the COMMITTED ASSIGNMENT stand whenever it was within `balMarginPct` of the
   target's pole.  That made "the derived assignment" a SET rather than a
   value, so `--check` could not tell a hysteresis-preserved incumbent from a
   stale hand edit: moving `diff_compiler_source_bytes` from `tools` to `types`
   by hand shifted the pole by 0s, and `--check` reported "already balanced".

   This is not that.  The incumbent is an EXPLICIT INPUT to a placement
   decision, consulted at a defined point in a defined order, and the result is
   still a single value that `--check` re-derives from committed data alone.
   `balTarget` is a pure function of a WIDER argument list — (rows, costs,
   toolchains, incumbent shards) — not a function with an escape hatch.  The
   discriminator is mechanical: under the reverted mechanism a hand edit was
   ACCEPTED because it was never re-derived; here a hand edit is re-derived like
   everything else, and survives only if the derivation independently produces
   it, which is what "derived" means.

   The rule.  Take the LPT pick (`balPick`) as the baseline, then keep the
   incumbent instead when all three hold:

     1. the incumbent row is OPEN (a closed row's members never reach here —
        `balOpenCands` filtered them — but the predicate is total anyway), and
     2. the incumbent row is LEGAL for this gate (`wasm_arm`), and
     3. the incumbent row is currently no more than `balStabPct` percent
        heavier than the LPT pick (`balStays`, which argues for BEFORE-adding
        rather than after).

   (2) is `balCurrentLegal`'s argument one layer down and is NOT negotiable:
   cost is what a preference may weigh, and legality is not a cost.  An illegal
   incumbent fails the predicate and is moved, which is what keeps the
   `wasm_only_row` fixture red-on-regression.

   ⚠️ WHY THIS IS STILL A FIXED POINT, which is the property #2178 paid for.
   Run the balancer on its own output and every candidate's incumbent IS the row
   the previous run placed it on.  By induction over the (identical) candidate
   order: if the previous run took the LPT pick, the incumbent equals the pick
   and clause (3) holds trivially with slack 0, so the pick is taken again; if
   the previous run kept the incumbent, the row states at that step are
   identical and the same three clauses hold, so it is kept again.  Either way
   the second run emits the first run's assignment, byte for byte —
   `diff_compiler_gate_balance.sh`'s `_bal_real`-twice assertion. -}
balPickStable : Cand -> List Row -> Option String
balPickStable c rs = match balPick c rs
  None => None
  Some best => if balStays c best rs then Some c.curRow else Some best

{- | Clause (1)+(2)+(3) of `balPickStable`, in that order.  Kept separate so the
   legality clause is a readable line rather than a term inside an arithmetic
   comparison.

   ⚠️ CLAUSE (3) COMPARES THE ROWS' LOADS BEFORE THIS GATE IS ADDED, NOT AFTER,
   AND THE TWO ARE NOT THE SAME RULE.  Both were implemented and measured; the
   before-form is kept, on both counts:

     * The bound it gives is the one worth having.  A hold puts this gate on a
       row already carrying `Lcur` instead of the lightest legal `Lbest`, and
       the excess it can add to the pole is exactly `Lcur - Lbest`, which this
       form caps at `balStabPct`% of `Lbest`.  The after-form caps the same
       excess at `balStabPct`% of `Lbest + cms`, so the slack GROWS with the
       gate's own cost — an expensive gate would earn more licence to sit on a
       heavy row, which is backwards for an objective that is the pole.
     * It measured no worse.  Same three ±2% perturbation shapes, churn out of
       202 gates: before-form 0 / 4 / 0, after-form 0 / 7 / 5.

   A consequence worth naming rather than discovering: early in the pack every
   row is near-empty, so `Lbest` is near 0 and the ABSOLUTE slack the
   preference tolerates is near 0 too — but the comparison is `Lcur * 100 <=
   Lbest * (100 + balStabPct)`, and when BOTH sides are exactly 0 (curRow and
   best both still-empty rows) that reduces to `0 <= 0`, which holds
   UNCONDITIONALLY regardless of `balStabPct`.  So the preference does not
   sit out the empty-row region — a gate committed to a still-empty row that
   is not bare LPT's pick is HELD there too, at zero cost either way (a
   fixed point, since every empty legal row is equally good).  What the
   biggest gates actually get placed by bare LPT with no preference in
   practice is the case where `curRow == best` already (ties broken in
   `[[shard]]` order tend to agree with the incumbent early on), not a
   genuine "preference disabled below some load" rule. -}
balStays : Cand -> String -> List Row -> Bool
balStays c best rs
  | c.curRow == best = True
  | not (balRowTakes c rs) = False
  | otherwise =
    balRowLoad c.curRow rs * 100 <= balRowLoad best rs * (100 + balStabPct)

-- Whether this gate's incumbent row exists, is open, and can run it.  An
-- unknown row name answers False — `balUnknownRows` has already refused that
-- registry, but a placement rule that read a missing row as "fine" would be one
-- refusal away from silently pinning a gate to nothing.
balRowTakes : Cand -> List Row -> Bool
balRowTakes _ [] = False
balRowTakes c (r :: rs)
  | r.rname == c.curRow = not r.rclosed && (not c.needsWasm || r.rwasm)
  | otherwise = balRowTakes c rs

-- One row's accumulated makespan, by name.  A row that does not exist reads as
-- 0, which `balStays` only ever reaches through `balRowTakes` having already
-- answered False for the same name.
balRowLoad : String -> List Row -> Int
balRowLoad _ [] = 0
balRowLoad n (r :: rs)
  | r.rname == n = r.rload
  | otherwise = balRowLoad n rs

-- Put one gate on a row, and re-derive that row's makespan.
--
-- ⚠️ THE CALLER OWES THIS FUNCTION COST-DESCENDING ORDER.  The within-row
-- schedule is LPT like the across-row one, and LPT's guarantee is a property of
-- the ORDER, not of the placement rule: fed a row's gates smallest-first, the
-- same buckets can end up markedly less even.  Every caller therefore feeds
-- `balSortCands` output — `balPlace`, `balSeedClosed` and `balCurrent` alike —
-- so the committed assignment and the derived one are scored by the same
-- model rather than by two schedules that happen to share a function.
balAdd : String -> Int -> List Row -> List Row
balAdd _ _ [] = []
balAdd n ms (r :: rs)
  | r.rname == n =
    let bs = balBucketAdd ms r.rbuckets
    Row { r | rbuckets = bs, rload = balMaxL bs, rcount = r.rcount + 1 } :: rs
  | otherwise = r :: balAdd n ms rs

-- One worker bucket takes the gate: the least-loaded one, first minimum kept,
-- which is what `xargs -P` does when a worker frees up.  An empty bucket list
-- cannot arise (`balJobsFor` floors at 1), but if it ever did, growing a bucket
-- is the one response that does not silently LOSE the gate's cost.
balBucketAdd : Int -> List Int -> List Int
balBucketAdd ms [] = ms :: []
balBucketAdd ms bs = balBucketPut ms (balMinL bs) bs

balBucketPut : Int -> Int -> List Int -> List Int
balBucketPut _ _ [] = []
balBucketPut ms m (b :: bs)
  | b == m = b + ms :: bs
  | otherwise = b :: balBucketPut ms m bs

balMinL : List Int -> Int
balMinL [] = 0
balMinL (x :: []) = x
balMinL (x :: xs) = minI x (balMinL xs)

balMaxL : List Int -> Int
balMaxL [] = 0
balMaxL (x :: xs) = maxI x (balMaxL xs)

-- Place the sorted candidates one at a time.  A gate with no legal row is the
-- constraint refusal: it names the gate, what it needs, and which rows offer
-- it, rather than quietly landing somewhere the toolchain is absent (where it
-- would fail in CI as a mysterious missing-binary error, on a row whose
-- coverage check reports the gate as scheduled).
--
-- `stab` selects the placement rule: `balPickStable` (the shipped one) or the
-- bare LPT `balPick`.  Both are needed on every run, because the report states
-- what the stability preference COSTS by packing the same candidates twice and
-- comparing the two poles (`balCompute`) — a claim about a trade-off that
-- printed only one side of it would be unfalsifiable by a reader.
balPlace : Bool ->
  List Cand ->
  List Row ->
  List Place ->
  Result String (List Place, List Row)
balPlace _ [] rs acc = Ok (reverseL acc, rs)
balPlace stab (c :: cs) rs acc = match (if stab then
  balPickStable c rs
else
  balPick c rs)
  None =>
    Err
      (stringConcat [
        "medaka gate balance: no row can run '\{c.cname}'.\n",
        "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n",
        "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ",
        joinSpace (balWasmRowNames rs),
        "\n",
      ])
  Some rn =>
    balPlace
      stab
      cs
      (balAdd rn c.cms rs)
      (Place {
          pname = c.cname,
          pfrom = c.curRow,
          pto = rn,
        }
        :: acc)

balWasmRowNames : List Row -> List String
balWasmRowNames [] = []
balWasmRowNames (r :: rs)
  | r.rwasm = r.rname :: balWasmRowNames rs
  | otherwise = balWasmRowNames rs

-- The closed rows keep exactly the gates that already name them.  A pinned
-- gate whose row cannot run it is a registry defect, not something to repack
-- around: the row is closed, so there is nowhere for it to go.
--
-- ⚠️ Reading `c.curRow` here is only sound because `balPinErrors` has already
-- refused any registry whose closed rows do not match their declared
-- `pinned_gates`.  Without that check this seed is the one place a `shard`
-- value is still hand-assignable, and the hand edit is adopted as the new pin.
balSeedClosed : List Cand ->
  List Row ->
  List Place ->
  Result String (List Place, List Row)
balSeedClosed [] rs acc = Ok (reverseL acc, rs)
balSeedClosed (c :: cs) rs acc
  | not (balIsClosed c.curRow rs) = balSeedClosed cs rs acc
  | c.needsWasm && not (balRowIsWasm c.curRow rs) =
    Err
      "medaka gate balance: '\{c.cname}' needs the Wasm toolchain but is pinned to row '\{c.curRow}', which has wasm_arm = false"
  | otherwise =
    balSeedClosed
      cs
      (balAdd c.curRow c.cms rs)
      (Place {
          pname = c.cname,
          pfrom = c.curRow,
          pto = c.curRow,
        }
        :: acc)

balIsClosed : String -> List Row -> Bool
balIsClosed _ [] = False
balIsClosed n (r :: rs)
  | r.rname == n = r.rclosed
  | otherwise = balIsClosed n rs

balRowIsWasm : String -> List Row -> Bool
balRowIsWasm _ [] = False
balRowIsWasm n (r :: rs)
  | r.rname == n = r.rwasm
  | otherwise = balRowIsWasm n rs

-- ── The closed rows' declared membership ────────────────────────

{- | 🚨 A CLOSED ROW'S MEMBERSHIP IS A DECLARED INVARIANT, NOT AN OBSERVATION.

   `balSeedClosed` seeds a `full_cores` row from whatever gates CURRENTLY name
   it.  As a packing rule that is right — the packer must move nothing onto a
   whole-runner row and nothing off it.  On its own, though, it leaves that row
   as the one place a `shard` value is still hand-assignable, which is exactly
   what #2178 exists to remove.  Two hand edits were accepted in review (F3),
   both adopted permanently by one `medaka gate balance` run, after which
   `--check` reported "already balanced":

     (a) move an unrelated gate ONTO `engines`.  The seed takes it, the packer
         repacks the other seven rows around the extra load, and the result is
         a fixed point of itself.
     (b) move `diff_compiler_engines` OFF `engines`.  Same adoption — and the
         projection printed is BETTER (pole/median 1.005 against 1.073, under
         the metric #2216 retired),
         because idling a whole runner and stacking the suite's heaviest gate
         onto a shared one is what a cost objective blind to the pin prefers.

   Neither is a cost fact, so neither can be derived.  It is DECLARED per row,
   in `[[shard]]`'s `pinned_gates`, and checked here against what the registry
   actually says — in BOTH directions.  Checking both is what makes this an
   invariant a wrong committed state can FAIL, rather than a fiat under which
   whatever is committed defines itself as correct.

   An OPEN row must declare `pinned_gates = []`: its membership IS the packer's
   output, and a non-empty list there would be prose the tool silently ignores.
   Every violation is reported, not just the first — a membership repair is one
   edit, and finding out about the second half of it on the next run is not. -}
balPinErrors : List Gate -> List Shard -> List String
balPinErrors _ [] = []
balPinErrors gs (s :: ss)
  | not s.fullCores && not (isEmptyStrs s.pinned) =
    "row '\{s.name}': pinned_gates is non-empty (\{joinSpace s.pinned}) on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"
      :: balPinErrors gs ss
  | not s.fullCores = balPinErrors gs ss
  | otherwise =
    let members = balRowMembers s.name gs
    balPinMissing s.name gs s.pinned members
      ++ balPinExtra s.name s.pinned members
      ++ balPinErrors gs ss

-- The gates whose committed `shard` names this row, in registry order.
balRowMembers : String -> List Gate -> List String
balRowMembers _ [] = []
balRowMembers n (g :: gs)
  | g.shard == n = g.name :: balRowMembers n gs
  | otherwise = balRowMembers n gs

-- Declared, but not there: the pinned gate has been moved off the closed row
-- (F3(b)).  Naming where it went instead is the whole diagnosis.
balPinMissing : String -> List Gate -> List String -> List String -> List String
balPinMissing _ _ [] _ = []
balPinMissing n gs (p :: ps) members
  | balElemStr p members = balPinMissing n gs ps members
  | otherwise = balPinPlace n gs p :: balPinMissing n gs ps members

balPinPlace : String -> List Gate -> String -> String
balPinPlace n gs p = match balShardOfGate p gs
  None => "row '\{n}': pinned gate '\{p}' is not in the registry at all"
  Some other =>
    "row '\{n}': pinned gate '\{p}' is committed on row '\{other}' instead"

balShardOfGate : String -> List Gate -> Option String
balShardOfGate _ [] = None
balShardOfGate n (g :: gs)
  | g.name == n = Some g.shard
  | otherwise = balShardOfGate n gs

-- There, but not declared: a gate has been moved onto the closed row (F3(a)).
balPinExtra : String -> List String -> List String -> List String
balPinExtra _ _ [] = []
balPinExtra n pinned (m :: ms)
  | balElemStr m pinned = balPinExtra n pinned ms
  | otherwise =
    "row '\{n}': '\{m}' is committed on this closed row but is not in its pinned_gates"
      :: balPinExtra n pinned ms

balElemStr : String -> List String -> Bool
balElemStr _ [] = False
balElemStr x (y :: ys)
  | x == y = True
  | otherwise = balElemStr x ys

balOpenCands : List Cand -> List Row -> List Cand
balOpenCands [] _ = []
balOpenCands (c :: cs) rs
  | balIsClosed c.curRow rs = balOpenCands cs rs
  | otherwise = c :: balOpenCands cs rs

{- | The target assignment: seed the closed rows from their current members,
   then pack the rest onto the open rows.

   ⚠️ A PURE FUNCTION OF (rows, costs, toolchains, INCUMBENT SHARDS).  That
   fourth input arrived with S-3/#2218's stability preference, and the wording
   of this paragraph used to be its own load-bearing claim, so read the change
   carefully rather than as a widening of scope:

   IT USED TO SAY "it does not read the `shard` of any gate on an OPEN row",
   and that was the right rule for the mechanism it described.  #2178's reverted
   hysteresis band did not take the incumbent as an argument — it took the
   derived target and then DECLINED TO EMIT IT if what happened to be committed
   scored close enough.  A function that can decline to emit its own output has
   no single value for `--check` to police, and a hand edit inside the band
   passed as "already balanced" (`balBandNote`).

   Reading `Cand.curRow` here is the opposite move, not a softening of it.
   `curRow` is populated from the COMMITTED registry (`balCands`), so it is
   ordinary committed input, exactly like `cms` and `needsWasm`; the function
   consumes it and returns ONE assignment, which `--check` re-derives from the
   same committed bytes and compares. Purity is a property of the argument
   list, not a property of arguments being few.

   Idempotence — the reason any of this care is spent — is unchanged and argued
   in `balPickStable`: on the balancer's own output every incumbent is the row
   the previous run chose, so every placement repeats and the second run is
   byte-identical.

   `stab` is False for the pure-LPT comparison run that `balCompute` scores the
   preference's pole cost against; the emitted assignment is always the True
   one. -}
balTarget : Bool ->
  List Cand ->
  List Row ->
  Result String (List Place, List Row)
balTarget stab cs rows0 =
  -- Cost-descending for BOTH halves, not just the packed one: `balAdd` now runs
  -- an LPT schedule inside each row, and a closed row seeded in registry order
  -- would be scored under a schedule CI never runs (`balAdd`'s note).  The
  -- pinned `Place`s are looked up by name downstream (`balPlaceOf`), so their
  -- order carries no meaning of its own.
  let sorted = balSortCands cs
  match balSeedClosed sorted rows0 []
    Err m => Err m
    Ok (pinned, rows1) =>
      map
        ((placed, rows2) => (pinned ++ placed, rows2))
        (balPlace stab (balSortCands (balOpenCands sorted rows0)) rows1 [])

-- The assignment already on disk, as the same shape, so the two can be scored
-- by identical code rather than by two functions that could drift apart.
--
-- ⚠️ Its caller passes `balSortCands` output, for `balAdd`'s reason: scoring the
-- committed assignment under registry order and the derived one under
-- cost-descending order would compare two DIFFERENT models and call the
-- difference a packing gain.
balCurrent : List Cand -> List Row -> (List Place, List Row)
balCurrent [] rs = ([], rs)
balCurrent (c :: cs) rs =
  let (ps, rs2) = balCurrent cs (balAdd c.curRow c.cms rs)
  (Place { pname = c.cname, pfrom = c.curRow, pto = c.curRow } :: ps, rs2)

-- ── Scoring ─────────────────────────────────────────────────────────────────

balPole : List Row -> Int
balPole [] = 0
balPole (r :: rs) = maxI r.rload (balPole rs)

balPoleRow : List Row -> String
balPoleRow rs = balPoleRowGo rs "" (-1)

balPoleRowGo : List Row -> String -> Int -> String
balPoleRowGo [] n _ = n
balPoleRowGo (r :: rs) n best
  | r.rload > best = balPoleRowGo rs r.rname r.rload
  | otherwise = balPoleRowGo rs n best

balLoads : List Row -> List Int
balLoads [] = []
balLoads (r :: rs) = r.rload :: balLoads rs

balSortInts : List Int -> List Int
balSortInts [] = []
balSortInts (x :: []) = x :: []
balSortInts xs =
  let (l, r) = balHalveI xs [] []
  balMergeInts (balSortInts l) (balSortInts r)

balHalveI : List Int -> List Int -> List Int -> (List Int, List Int)
balHalveI [] a b = (a, b)
balHalveI (x :: xs) a b = balHalveI xs b (x :: a)

balMergeInts : List Int -> List Int -> List Int
balMergeInts [] ys = ys
balMergeInts xs [] = xs
balMergeInts (x :: xs) (y :: ys)
  | x <= y = x :: balMergeInts xs (y :: ys)
  | otherwise = y :: balMergeInts (x :: xs) ys

-- The median row load: the mean of the two middle values for an even row
-- count, the middle value for an odd one.
--
-- ⚠️ DESCRIPTIVE ONLY SINCE S-4 (#2216) — it enforces nothing.  It was the
-- denominator of the old `pole / median` target and is kept because it is the
-- one number that tells a reader at a glance how far the typical row sits from
-- the pole, which the per-row table shows but does not summarise.  It is NOT a
-- component of `balFloor`: a median is a property of the suite, and mixing one
-- into the floor would put the perversity this slice removed straight back.
balMedian : List Row -> Int
balMedian rs =
  let v = balSortInts (balLoads rs)
  let n = listLen v
  if n == 0 then
    0
  else if n % 2 == 1 then
    balNth (n / 2) v
  else
    (balNth (n / 2 - 1) v + balNth (n / 2) v) / 2

balNth : Int -> List Int -> Int
balNth _ [] = 0
balNth i (x :: xs)
  | i <= 0 = x
  | otherwise = balNth (i - 1) xs

-- ── The floor: the achievable pole ──────────────────────────────────────────
--
-- The largest of three lower bounds on the pole, each proved in "The
-- objective" above.  A floor of 0 (no rows, no gates) is reported as a factor
-- of 0 by `balFactorMilli`, matching what the old ratio did with a zero
-- median: there is nothing to grade, and `balEnforce` must not divide by it.

-- Term 1: the most expensive single gate.  Over ALL gates, closed-row members
-- included — whichever row holds it, that row's makespan is at least its cost.
balFloorGateMs : List Cand -> Int
balFloorGateMs cs = (balMaxCand cs).cms

-- Term 2: the heaviest closed row's makespan.  A `full_cores` row's membership
-- is declared, not packed (`balSeedClosed`), so its load is fixed input and the
-- pole is at least that.  Blaming the packer for it would be the same category
-- error as blaming it for one indivisible gate.
balFloorClosedMs : List Row -> Int
balFloorClosedMs [] = 0
balFloorClosedMs (r :: rs)
  | r.rclosed = maxI r.rload (balFloorClosedMs rs)
  | otherwise = balFloorClosedMs rs

balFloorClosedRow : List Row -> String
balFloorClosedRow rs = balFloorClosedRowGo rs "" (-1)

balFloorClosedRowGo : List Row -> String -> Int -> String
balFloorClosedRowGo [] n _ = n
balFloorClosedRowGo (r :: rs) n best
  | r.rclosed && r.rload > best = balFloorClosedRowGo rs r.rname r.rload
  | otherwise = balFloorClosedRowGo rs n best

-- The open gates' total work.  Closed-row members are excluded on BOTH sides of
-- the capacity term (here and in `balOpenSlots`): they cannot move, so they are
-- neither work the packer has to place nor capacity it has to place it on.
balOpenWork : List Cand -> List Row -> Int
balOpenWork [] _ = 0
balOpenWork (c :: cs) rs
  | balIsClosed c.curRow rs = balOpenWork cs rs
  | otherwise = c.cms + balOpenWork cs rs

-- The open rows' worker slots.  `rjobs`, not 1: a row runs its gates through
-- `run_gates.sh`'s pool, so its capacity per unit of wall clock is its recorded
-- worker count (`balJobsFor`), and counting rows instead of slots would inflate
-- this term by roughly `jobs`×.
balOpenSlots : List Row -> Int
balOpenSlots [] = 0
balOpenSlots (r :: rs)
  | r.rclosed = balOpenSlots rs
  | otherwise = r.rjobs + balOpenSlots rs

-- Term 3: total open work spread perfectly over every open worker slot.
balFloorCapMs : List Cand -> List Row -> Int
balFloorCapMs cs rs =
  let s = balOpenSlots rs
  if s <= 0 then 0 else balOpenWork cs rs / s

balFloor : List Cand -> List Row -> Int
balFloor cs rs =
  maxI (balFloorGateMs cs) (maxI (balFloorClosedMs rs) (balFloorCapMs cs rs))

-- True when the floor is set by one indivisible gate rather than by capacity or
-- by a closed row — the discriminator `balEnforce` needs to choose between "this
-- is the packing" and "this gate has to get FASTER".  Ties go to the gate: when
-- the terms are equal, the gate is the one a reader can act on.
balFloorIsGate : List Cand -> List Row -> Bool
balFloorIsGate cs rs = balFloorGateMs cs >= balFloor cs rs

-- Where the floor comes from, in one line, on every run.  A bound with no
-- stated provenance is a number a reader has to reverse-engineer before they
-- can act on the ratio built from it.
balFloorLine : List Cand -> List Row -> String
balFloorLine cs rs
  | balFloor cs rs <= 0 = ""
  | balFloorIsGate cs rs = stringConcat [
    "  floor: the achievable pole — set by '\{(balMaxCand cs).cname}' alone (\{balSecs (balFloorGateMs cs)}), which is indivisible.\n",
    "         Moving the FLOOR means that gate has to get FASTER (or be split).\n",
  ]
  | balFloorClosedMs rs >= balFloor cs rs =
    "  floor: the achievable pole — set by the closed row '\{balFloorClosedRow rs}' (\{balSecs (balFloorClosedMs rs)}), whose membership the packer cannot change.\n"
  | otherwise =
    "  floor: the achievable pole — set by \{balSecs (balOpenWork cs rs)} of open work over \{intToString (balOpenSlots rs)} open worker slots.\n"

-- `pole / floor` in thousandths.  Integer arithmetic throughout: the factor
-- is compared against a threshold and printed, and a float would make both
-- the comparison and the printed digits platform-sensitive for no gain.
balFactorMilli : List Cand -> List Row -> Int
balFactorMilli cs rs =
  let f = balFloor cs rs
  if f <= 0 then 0 else balPole rs * 1000 / f

balMaxCand : List Cand -> Cand
balMaxCand [] =
  Cand { cname = "(none)", crun = "", curRow = "", cms = 0, needsWasm = False }
balMaxCand (c :: []) = c
balMaxCand (c :: cs) =
  let r = balMaxCand cs
  if c.cms >= r.cms then c else r

-- ── Rendering ───────────────────────────────────────────────────────────────

-- Milliseconds as `948.9s` — one decimal, which is all the precision a median
-- of nine noisy CI samples supports.
balSecs : Int -> String
balSecs ms = "\{intToString (ms / 1000)}.\{intToString (ms % 1000 / 100)}s"

-- Per-mille as a one-decimal percentage magnitude, `126` -> `12.6%`.
balTenth : Int -> String
balTenth pm = "\{intToString (pm / 10)}.\{intToString (pm % 10)}%"

-- A signed one-decimal percentage of `base`, as `-12.6%`.  Integer
-- arithmetic, for `balFactorMilli`'s reason, and the sign is applied to the
-- MAGNITUDE rather than carried through the division — `balDelta`'s trap,
-- where both halves of an integer split carry the sign and a negative renders
-- as `-1.-4`.
balPct1 : Int -> Int -> String
balPct1 d base
  | base <= 0 = "n/a"
  | d < 0 = "-\{balTenth ((0 - d) * 1000 / base)}"
  | otherwise = "+\{balTenth (d * 1000 / base)}"

-- Thousandths as `1.074`.
balMilli : Int -> String
balMilli m = "\{intToString (m / 1000)}.\{balPad3 (m % 1000)}"

balPad3 : Int -> String
balPad3 n
  | n < 10 = "00\{intToString n}"
  | n < 100 = "0\{intToString n}"
  | otherwise = intToString n

balPadR : Int -> String -> String
balPadR w s
  | stringLength s >= w = s
  | otherwise = balPadR w (s ++ " ")

balPadL : Int -> String -> String
balPadL w s
  | stringLength s >= w = s
  | otherwise = balPadL w (" " ++ s)

-- A signed millisecond delta as `+14.3s` / `-2.0s`.  `balSecs` alone renders a
-- negative as `-1.-4s`, because both halves of its integer split carry the
-- sign; the residual column is the first place negatives occur.
balDelta : Int -> String
balDelta d
  | d < 0 = "-\{balSecs (0 - d)}"
  | otherwise = "+\{balSecs d}"

-- Every row's per-gate load is its makespan; the worker count it was modelled
-- with is printed beside it, and a borrowed or defaulted one says so — a row
-- silently modelled serially among 2-worker siblings would misprice by 2× with
-- nothing in the output to show for it (`balJobsFor`).
balRowLines : List Row -> List RunRecord -> List String
balRowLines [] _ = []
balRowLines (r :: rs) runs =
  let tag = if r.rclosed then "  [closed: full_cores]" else ""
  let jt = if balJobsIsFallback r.rname runs then " jobs*" else " jobs "
  "    \{balPadR 10 r.rname} \{balPadL 4 (intToString r.rcount)} gates \{balPadL 9 (balSecs r.rload)}  \{jt}\{intToString r.rjobs}\{tag}"
    :: balRowLines rs runs

{- | The model against something that is not the model: each row's recorded CI
   wall clock (`rowElapsedMs`, S-1/#2208) beside this model's makespan for the
   COMMITTED assignment, and the residual between them.

   ⚠️ READ THE CAVEAT BEFORE READING THE NUMBERS.  A residual is only meaningful
   while the recorded run and the committed assignment describe the SAME gate
   set — that is true right after an ingest and false the moment a rebalance
   lands, because the next run has not happened yet.  So this block is
   calibration evidence at ingest time, not a live invariant, and it is
   reported rather than enforced for exactly that reason.  The line CANNOT
   detect that on its own — a residual reads identically whether the gate set
   moved or not — so `balCalibStaleness` annotates the line when the recorded
   run and the committed row have drifted apart, comparing the recorded
   `gates` COUNT (F-2, #2178 review S2-1) and, when the run recorded one, the
   recorded gate-SET digest (S-2, #2223) — because a rebalance that swaps one
   gate for another leaves the count alone and would otherwise report clean.

   The residual is expected to be POSITIVE and not zero.  A row's recorded
   elapsed spans things no per-gate median contains:

     * the pool's own spawn overhead (still real);
     * the packing statistic is the LOWER MEDIAN of a gate's retained raw
       samples, which is systematically LOW — and, since S-2 (#2222), by a
       MEASURED amount rather than an asserted one: leave-one-run-out over
       the runs recorded in `runs[]` puts the bias at -12.6% of a row's
       predicted total.  That is the deliberate price of a statistic one wild
       sample cannot move (`gate_cost.packStat`'s doc-comment carries the
       comparison that settled it), and `balOosLines` prints the current
       figure on every run rather than leaving this prose to rot; and
     * gates that FAILED, which contribute wall clock to the row but, by the
       ingester's rule, no sample to the baseline.  Whether this is currently
       vacuous is DERIVED, not asserted here: `balOosBlock` reports how many
       schedulable gates carry a run-attributed sample from EVERY recorded
       run, and it is vacuous exactly when that count is all of them, since a
       gate that failed a run is a gate short that run's sample.  ⚠️ On a
       baseline predating `sampleRuns` that count is 0 for want of
       attribution, not for want of samples, and `balOosBlock` says which —
       do not read its "not derivable" line as evidence that gates failed.
       (An earlier version of this comment pinned the state as a fact —
       "every gate ... at `samples: 2` across both ingested runIds" — and it
       was stale within two ingests.  Hence the derivation.)

   The gate's own shebang syntax pre-check is NOT a cause: `test/run_gates.sh`
   starts the clock BEFORE that check runs (search "clock starts BEFORE the
   syntax pre-check"), so its cost is already inside each gate's own `ms` and
   cannot also be part of the residual.

   A residual near zero or negative is the surprising one. -}
balCalibLines : List Cand -> List Row -> List RunRecord -> List String
balCalibLines _ [] _ = []
balCalibLines cs (r :: rs) runs =
  balCalibLine cs r runs :: balCalibLines cs rs runs

{- | The recorded run and the committed assignment describe the same gate set
   only as long as the row has not been rebalanced since that run.  Two
   independent comparisons answer that, and BOTH are needed:

     1. `rcount` (now) against the run's own recorded `gates` (at ingest).
     2. The row's current gate-SET digest against the run's recorded
        `gatesDigest`.

   🚨 (1) ALONE IS A COUNT, AND A COUNT IS NOT A SET (#2223).  The commonest
   rebalance is a SWAP — one gate leaves the row, another arrives — and a swap
   is invisible to (1) by construction.  The observed instance was a -96%
   residual printing entirely clean, which reads as "the model is calibrated"
   when it means "the model is being graded against a gate set that has not
   existed since the rebalance". (2) is what closes it.

   `None` on either side (a run ingested before that field existed) is
   silently unannotated — "unknown" is not "stale" — so a baseline predating
   `gatesDigest` keeps exactly the count-only behaviour it had, and gains the
   set check at its next ingest. -}
balCalibStaleness : Int -> Option Int -> Int -> Option Int -> String
balCalibStaleness _ None _ _ = ""
balCalibStaleness cur (Some recorded) curDig recDig
  | cur /= recorded =
    " [STALE: \{intToString cur} gates now, \{intToString recorded} when recorded]"
  | otherwise = balCalibSetStaleness cur curDig recDig

balCalibSetStaleness : Int -> Int -> Option Int -> String
balCalibSetStaleness _ _ None = ""
balCalibSetStaleness n cur (Some recorded)
  | cur == recorded = ""
  | otherwise =
    " [STALE: the same \{intToString n} gates by COUNT but a DIFFERENT SET (set digest \{intToString cur} now, \{intToString recorded} when recorded)]"

-- The digest of what is committed to this row NOW, over the same population
-- `rcount` counts: the candidates whose COMMITTED shard is this row.  Keyed
-- by `baselineKey c.crun`, never by `c.cname` — the ingester digests
-- `run_gates.sh`'s labels, and those are the flattened script paths, not the
-- registry names (`gate_cost`'s module header carries why that distinction
-- silently bites 53 of the 202 entries).
balRowDigest : String -> List Cand -> Int
balRowDigest rn cs = gateSetDigest (balRowKeys rn cs)

balRowKeys : String -> List Cand -> List String
balRowKeys _ [] = []
balRowKeys rn (c :: cs)
  | c.curRow == rn = baselineKey c.crun :: balRowKeys rn cs
  | otherwise = balRowKeys rn cs

balCalibLine : List Cand -> Row -> List RunRecord -> String
balCalibLine cands r runs = match latestRunForShard r.rname runs
  None => "    \{balPadR 10 r.rname} (no recorded run)"
  Some rr => match rr.rowElapsedMs
    None =>
      "    \{balPadR 10 r.rname} (run \{rr.runId} recorded no rowElapsedMs)"
    Some e =>
      let d = e - r.rload
      let pct =
        if r.rload > 0 then " (\{intToString (d * 100 / r.rload)}%)" else ""
      let stale =
        balCalibStaleness
          r.rcount
          rr.gates
          (balRowDigest r.rname cands)
          rr.gatesDigest
      "    \{balPadR 10 r.rname} recorded \{balPadL 9 (balSecs e)}   predicted \{balPadL 9 (balSecs r.rload)}   residual \{balPadL 9 (balDelta d)}\{pct}\{stale}"

{- | What the incumbent preference bought, and what it cost — on EVERY run, in
   ordinary output, derived rather than asserted.

   The trade `balStabPct` makes is churn against pole, and a tool that made it
   silently would be asking a reader to take both halves on faith.  So the same
   candidates are packed a SECOND time with the preference off (`balTarget
   False`) and the two results are compared directly: how many gates the
   preference held where bare LPT would have moved them, and what the achieved
   pole is under each.

   ⚠️ ON AN UNPERTURBED, ALREADY-BALANCED REGISTRY BOTH NUMBERS ARE ZERO, AND
   THAT IS THE HEALTHY READING, NOT A BROKEN COMPARISON.  The committed
   assignment IS the LPT output, so every incumbent already equals the LPT pick
   and the preference never fires.  It fires when the baseline moves under it —
   which is the only situation it exists for.  A reader seeing "0 held, +0.0s"
   after a re-ingest that moved nothing is being told the truth.

   The comparison arm cannot fail where the emitted arm succeeded
   (`balPickStable` returns `None` exactly when `balPick` does, and the closed-row
   seed is identical), but a `Result` is still a `Result`: rather than paper over
   an impossible case with a zero, say the comparison is unavailable. -}
balStabLine : List Cand -> List Row -> List Place -> List Row -> String
balStabLine cs rows0 ps rows = match balTarget False cs rows0
  Err _ =>
    "  stability: the unstabilized comparison packing could not be derived\n"
  Ok (lps, lrows) => stringConcat [
    "  stability: \{intToString (balHeldCount ps lps)} of \{intToString (listLen ps)} gates held on their committed row",
    " (incumbent slack \{intToString balStabPct}% of a row's load)",
    "; pole \{balSecs (balPole rows)} against \{balSecs (balPole lrows)} unstabilized",
    " (\{balDelta (balPole rows - balPole lrows)}),",
    " pole/floor \{balMilli (balFactorMilli cs rows)} against \{balMilli (balFactorMilli cs lrows)}\n",
  ]

-- Gates the preference actually HELD: still on the row they were committed to,
-- where the bare-LPT packing would have moved them.
--
-- ⚠️ NOT "gates the two packings disagree about", which is the larger and
-- misleading number.  Holding one gate shifts the row loads every LATER
-- placement is measured against, so bare LPT and the stabilized packing can
-- also disagree about gates that were themselves MOVED — `stability_preference`
-- has exactly one of each, and reporting 2 there under the word "held" would be
-- a count that does not mean what the sentence around it says.
balHeldCount : List Place -> List Place -> Int
balHeldCount [] _ = 0
balHeldCount (p :: ps) qs
  | p.pto == p.pfrom && balPlaceOf p.pname qs /= p.pto = 1 + balHeldCount ps qs
  | otherwise = balHeldCount ps qs

balMoved : List Place -> Int
balMoved [] = 0
balMoved (p :: ps)
  | p.pfrom /= p.pto = 1 + balMoved ps
  | otherwise = balMoved ps

-- ── Thin-evidence visibility (S-4, #2178/#2207) ─────────────────────────────
--
-- "A gate balanced off a single sample is a fact the tool states, not one a
-- reader has to go find." Bucketing (above) makes the SCORE tolerant of
-- ordinary noise; it does not make a one-sample median any less thin. Both
-- facts are true at once, so both get reported.
balThinSamples : Int
balThinSamples = 2

balThinCount : List GateCost -> Int
balThinCount [] = 0
balThinCount (c :: cs)
  | c.samples < balThinSamples = 1 + balThinCount cs
  | otherwise = balThinCount cs

-- Printed unconditionally in ordinary output (never behind a flag): even
-- "0 of N" is worth stating, because it is the reader's evidence that the
-- baseline is not currently resting on single-sample data, not merely an
-- absence of a warning they might otherwise wonder about.
balThinLine : List GateCost -> String
balThinLine base =
  "  \{intToString (balThinCount base)} of \{intToString (listLen base)} gates are scheduled off a single sample (samples < \{intToString balThinSamples})\n"

-- ── Out-of-sample error of the packing statistic (S-2, #2222) ───────────────

{- | What the packing statistic's estimates are actually WORTH, printed in
   ordinary output beside the projection they underwrite.

   Before S-2 the balancer scheduled on `medianMs` with NO STATED ERROR: every
   number in this report was a point estimate presented as if exact, and the
   only account of its accuracy was a prose claim in `balCalibLines` that the
   median "systematically underestimates".  True, as it turns out — but nobody
   had measured by how much, and the two doc-comments asserting the baseline's
   sample state had both gone stale within two ingests.  A figure the tool
   derives on every run cannot rot that way.

   THE PROTOCOL, and why it is out-of-sample.  An estimate validated against
   the samples that defined it is an in-sample residual and is worth nothing:
   the median of three numbers is trivially close to those three numbers.  So
   each recorded run is held out in turn, the statistic for every gate is
   recomputed from the OTHER runs' samples ONLY, and the sum of those
   estimates is scored against the held-out run's actual total.  No estimate
   is ever graded against a sample that helped produce it.

   ⚠️ LEAVING OUT A RUN REQUIRES KNOWING WHICH SAMPLE CAME FROM IT, AND THAT
   IS READ, NEVER INFERRED (FR-1, #2222 review S0-1).  Until FR-1 this block
   inferred it: `ms[i]` was taken to be the i-th retained run's sample whenever
   a gate's `samples` equalled the number of distinct runIds in `runs[]`, on
   the argument that a gate receives at most one sample per run.  The premise
   is true and the conclusion does not follow.  `test/gate_cost_ingest.sh`
   trims `runs[]` by total ROW count (`MAX_RUNS`, one row per
   `runId:runAttempt:shard`) and each gate's `ms` by SAMPLE count
   (`MAX_SAMPLES`), independently, per gate — the two counters are unrelated,
   and they agreed only because the committed file happened to hold exactly
   3 runs x 8 shards with no gate having ever missed one.  One gate failing
   one run puts that gate's count back to equal with the ALIGNMENT wrong, and
   every fold then grades one run's estimate against a different run's
   measurement, at exit 0, with no warning.

   So the join is now by runId, exactly: a gate contributes its sample for
   fold `i` only if exactly one of its `sampleRuns` entries equals the i-th
   recorded runId.  Zero matches (a failed gate, a sample older than the
   retained run window, or a legacy sample with no attribution at all) and
   ambiguous matches (two samples claiming one runId) both EXCLUDE the gate
   rather than positioning it.

   ⚠️ THE ADMITTED SET IS THE SAME ACROSS EVERY FOLD, DELIBERATELY.  A gate
   missing run 2's sample could still be folded into runs 1 and 3, but then
   each row of the table below would be a sum over a different set of gates
   and the `predicted`/`actual` columns would not be comparable row to row —
   a reader would be looking at three totals of three different things.  So
   the admission is all-or-nothing per gate: a gate is folded in only if it
   carries an exactly attributed sample for EVERY recorded run, and the
   header states how many gates that is out of how many are schedulable.

   ⚠️ AND IF NOTHING QUALIFIES, THERE IS NO NUMBER.  A baseline whose samples
   predate `sampleRuns` (every baseline committed before FR-1) has no
   attribution to join on, so this block prints what it does not know and how
   many samples that verdict rests on.  It never falls back to the count-based
   inference: the whole defect was a plausible number where an absence
   belonged.

   A gate short a sample is also exactly the case the `balCalibLines` residual
   blames on failed gates, so the two accounts stay consistent.

   ⚠️ THE FIGURE IS AN UPPER BOUND ON THE PRODUCTION ERROR, NOT AN ESTIMATE OF
   IT.  Holding out one of N samples trains the statistic at N-1, one below
   what the committed file actually schedules from, and fewer samples is
   strictly worse.  Read it as "no worse than this". -}
balOosBlock : List GateCost -> List Cand -> List RunRecord -> String
balOosBlock base cs runs =
  let ids = balRunIds runs []
  let nr = listLen ids
  if nr < 2 then
    "  out-of-sample error of the packing statistic: not derivable (\{intToString nr} recorded run(s); predicting one run from the others needs at least two)\n"
  else
    let vs = balOosVecs base cs ids
    let ne = listLen vs
    if ne == 0 then
      "  out-of-sample error of the packing statistic: not derivable — \{intToString (balAttrKnown base cs)} of \{intToString (balAttrTotal base cs)} retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the \{intToString nr} recorded runs\n"
    else
      stringConcat [
        "  out-of-sample error of the packing statistic (leave-one-run-out over the \{intToString nr} runs in runs[], across the \{intToString ne} of \{intToString (listLen cs)} schedulable gates carrying a run-attributed sample from every run):\n",
        joinNl (balOosFolds vs ids 0 nr),
        "\n",
        balOosSummary vs nr,
        balOosDriftLine base,
      ]

balOosFolds : List (List Int) -> List String -> Int -> Int -> List String
balOosFolds vs ids i nr
  | i >= nr = []
  | otherwise =
    let p = balOosPred vs i
    let a = balOosAct vs i
    "    run \{balPadR 13 (balNthStr i ids)} predicted \{balPadL 9 (balSecs p)}   actual \{balPadL 9 (balSecs a)}   \{balPadL 7 (balPct1 (p - a) a)}"
      :: balOosFolds vs ids (i + 1) nr

-- The bias is the number a reader should carry away, so it says which way it
-- points: the median is the LOW-side robust choice, and the underestimate is
-- the price of a statistic one wild sample cannot move.  `gate_cost.packStat`
-- carries the measurement that settled that trade.
balOosSummary : List (List Int) -> Int -> String
balOosSummary vs nr =
  let p = balOosPredAll vs 0 nr
  let a = balOosActAll vs 0 nr
  "    mean |error| \{balTenth (balOosAbsPm vs 0 nr 0 / nr)}   systematic bias \{balPct1 (p - a) a} (the median is the low-side robust choice — see gate_cost.packStat)\n"

-- `packStat` and the committed `medianMs` are two spellings of ONE rule, kept
-- equal only by `test/gate_cost_ingest.sh`'s awk `median()` and
-- `gate_cost.packStat` agreeing.  Counting the rows where they disagree turns
-- a drift between those two into a printed number rather than a silently
-- different score.  Expected to be 0, and printed only when it is not.
balOosDriftLine : List GateCost -> String
balOosDriftLine base =
  let n = balStatDrift base
  if n == 0 then
    ""
  else
    "    WARNING: \{intToString n} baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n"

balStatDrift : List GateCost -> Int
balStatDrift [] = 0
balStatDrift (c :: cs)
  | packStat c.ms == c.medianMs = balStatDrift cs
  | otherwise = 1 + balStatDrift cs

-- The sample vectors of the schedulable gates that carry an exactly
-- run-attributed sample for every recorded run, each REORDERED into `ids`
-- order so that index i genuinely is run i — which is the property the whole
-- block turns on and the property the old count check did not establish.  A
-- gate the baseline has no row for is already a hard error upstream
-- (`balUncosted`), so the `None` arm here is unreachable in a real run and
-- drops rather than guesses.
balOosVecs : List GateCost -> List Cand -> List String -> List (List Int)
balOosVecs _ [] _ = []
balOosVecs base (c :: cs) ids = match costRowOf c.crun base
  None => balOosVecs base cs ids
  Some g => match balOosVecFor g ids
    None => balOosVecs base cs ids
    Some v => v :: balOosVecs base cs ids

-- `Some v` only when EVERY id resolves; one miss drops the whole gate, per
-- the "same admitted set across every fold" rule in `balOosBlock`.
balOosVecFor : GateCost -> List String -> Option (List Int)
balOosVecFor _ [] = Some []
balOosVecFor g (r :: rs) = match balSampleForRun r g.ms g.sampleRuns None
  None => None
  Some v => map (v :: _) (balOosVecFor g rs)

-- The one sample of `g` attributed to run `r`, or `None` if there are zero or
-- more than one.  TWO is as disqualifying as zero: a runId that appears twice
-- in one gate's `sampleRuns` (a re-run recorded under a second runAttempt,
-- say) leaves no fact about which of the two samples "is" that run, and
-- picking either would be the same guess in a smaller costume.  An
-- unattributed sample carries the empty string and matches no real runId, so
-- legacy rows fall out here without a special case.
balSampleForRun : String -> List Int -> List String -> Option Int -> Option Int
balSampleForRun _ [] _ acc = acc
balSampleForRun _ _ [] acc = acc
balSampleForRun r (m :: ms) (s :: ss) acc
  | s /= r = balSampleForRun r ms ss acc
  | otherwise = match acc
    None => balSampleForRun r ms ss (Some m)
    Some _ => None

-- How many retained samples across the schedulable gates carry ANY run
-- attribution, and how many there are in total.  Printed together in the
-- not-derivable line so the reader can tell "this baseline predates the
-- field" (0 of N) from "attribution exists but no gate spans every run".
balAttrKnown : List GateCost -> List Cand -> Int
balAttrKnown _ [] = 0
balAttrKnown base (c :: cs) = match costRowOf c.crun base
  None => balAttrKnown base cs
  Some g => balCountAttr g.sampleRuns + balAttrKnown base cs

balCountAttr : List String -> Int
balCountAttr [] = 0
balCountAttr (s :: ss)
  | s == "" = balCountAttr ss
  | otherwise = 1 + balCountAttr ss

balAttrTotal : List GateCost -> List Cand -> Int
balAttrTotal _ [] = 0
balAttrTotal base (c :: cs) = match costRowOf c.crun base
  None => balAttrTotal base cs
  Some g => listLen g.ms + balAttrTotal base cs

balOosPred : List (List Int) -> Int -> Int
balOosPred [] _ = 0
balOosPred (v :: vs) i = packStat (balDropNth i v) + balOosPred vs i

balOosAct : List (List Int) -> Int -> Int
balOosAct [] _ = 0
balOosAct (v :: vs) i = balNth i v + balOosAct vs i

balOosPredAll : List (List Int) -> Int -> Int -> Int
balOosPredAll vs i nr
  | i >= nr = 0
  | otherwise = balOosPred vs i + balOosPredAll vs (i + 1) nr

balOosActAll : List (List Int) -> Int -> Int -> Int
balOosActAll vs i nr
  | i >= nr = 0
  | otherwise = balOosAct vs i + balOosActAll vs (i + 1) nr

-- Per-fold RELATIVE errors, summed in per-mille and averaged by the caller.
-- Per-fold rather than pooled: a fold's own total is the denominator its own
-- error means anything against.
balOosAbsPm : List (List Int) -> Int -> Int -> Int -> Int
balOosAbsPm vs i nr acc
  | i >= nr = acc
  | otherwise =
    let p = balOosPred vs i
    let a = balOosAct vs i
    let d = if p >= a then p - a else a - p
    balOosAbsPm vs (i + 1) nr (acc + (if a > 0 then d * 1000 / a else 0))

balDropNth : Int -> List Int -> List Int
balDropNth _ [] = []
balDropNth i (x :: xs)
  | i <= 0 = xs
  | otherwise = x :: balDropNth (i - 1) xs

-- The distinct runIds of `runs[]`, in file order (oldest first) — the same
-- order `ms` is appended in, which is what makes index i mean run i.
balRunIds : List RunRecord -> List String -> List String
balRunIds [] acc = balRevStrs acc []
balRunIds (r :: rs) acc
  | balHasStr r.runId acc = balRunIds rs acc
  | otherwise = balRunIds rs (r.runId :: acc)

balHasStr : String -> List String -> Bool
balHasStr _ [] = False
balHasStr s (x :: xs)
  | x == s = True
  | otherwise = balHasStr s xs

balRevStrs : List String -> List String -> List String
balRevStrs [] acc = acc
balRevStrs (x :: xs) acc = balRevStrs xs (x :: acc)

balNthStr : Int -> List String -> String
balNthStr _ [] = ""
balNthStr i (x :: xs)
  | i <= 0 = x
  | otherwise = balNthStr (i - 1) xs

-- The projection block both `--check` and the mutating form print, verbatim.
-- One renderer, so the two can never describe different packings.
balReport : String ->
  List Cand ->
  List Row ->
  List Place ->
  List RunRecord ->
  String
balReport label cs rs ps runs = stringConcat [
  "  \{label}: \{intToString (listLen cs)} schedulable gates over \{intToString (listLen rs)} rows\n",
  "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n",
  joinNl (balRowLines rs runs),
  "\n  pole \{balSecs (balPole rs)} (\{balPoleRow rs})   median \{balSecs (balMedian rs)}   floor \{balSecs (balFloor cs rs)}   pole/floor \{balMilli (balFactorMilli cs rs)}\n",
  balFloorLine cs rs,
  "  gates whose row changes: \{intToString (balMoved ps)}\n",
]

-- ── The decision ────────────────────────────────────────────────────────────

-- ⚠️ HYSTERESIS MUST NEVER PRESERVE AN ILLEGAL ASSIGNMENT.
--
-- This is the first test for a reason, and it was not in the first draft: the
-- `wasm_only_row` fixture caught it.  There, a gate needing wasm-tools sat on
-- a row with `wasm_arm = false`, and moving it to the one legal row changed
-- the pole by 10ms out of 310 — far inside the 5% band.  So the balancer
-- reported "unchanged (within the hysteresis band)", exited 0, and left the
-- gate scheduled on a row where its toolchain is absent.
--
-- A band that damps churn is correct; a band that damps a CORRECTNESS repair
-- is a silent wrong answer.  Cost is what the margin is allowed to weigh, and
-- legality is not a cost.
balCurrentLegal : List Cand -> List Row -> Bool
balCurrentLegal [] _ = True
balCurrentLegal (c :: cs) rs
  | c.needsWasm && not (balRowIsWasm c.curRow rs) = False
  | otherwise = balCurrentLegal cs rs

{- | 🚨 THE BAND ANNOTATES; IT NO LONGER DECIDES (S-4, #2178).

   S-3 gave the band a THIRD job beyond damping churn: when the committed
   assignment differed from the target by less than `balMarginPct` of the pole,
   the balancer kept the committed one and exited 0.  That made "the derived
   assignment" a SET rather than a value, and a check can only ever police a
   value.  Measured on the balanced registry, moving `diff_compiler_source_bytes`
   from `tools` to `types` by hand shifted the pole by 0s, so
   `medaka gate balance --check` reported *"already balanced"* and exited 0 —
   the hand edit this slice exists to make red.

   The argument is S-3's own, one step further.  Its comment above says a band
   that damps a CORRECTNESS repair is a silent wrong answer, because "legality
   is not a cost".  DERIVEDNESS is not a cost either: the whole point of
   #2178 is that `shard` stops being data a human may choose, and a band that
   silently ratifies a human's choice is that property's only hole.

   So the emitted assignment is now always `balTarget` — a pure function of
   (rows, costs, toolchains).  The band survives as the REPORT's account of how
   much a move was worth, and `balMarginPct` is still what that account is
   measured against.

   Idempotence is unaffected and is now trivial rather than argued: the target
   is a fixed point of itself, so a second run on an unchanged baseline emits
   byte-identical text and `balWrite` writes nothing.

   What the band cost, and what is paid for it: a baseline re-ingest whose
   noise moves a gate now moves that gate in `test/gates.toml` too, so a
   re-ingest commit carries a matrix reshuffle it used to be able to skip.
   That is the price of the assignment being checkable at all, and the repair
   is two mechanical commands (`medaka gate balance`, `make gen-ci`), not a
   judgement call.

   🚨 THAT PRICE IS NOW PARTLY PAID BACK, AND NOT BY REINSTATING THIS BAND
   (S-3, #2218).  Re-ingests became scheduled (S-1), so "a reshuffle per
   re-ingest" stopped being occasional: measured on this registry, an ordinary
   ±2% perturbation moved 89–128 of 202 gates.  The response is
   `balPickStable` — an incumbent preference INSIDE the packing, taking the
   committed `shard` as an explicit argument — and the distinction from what
   this comment describes is the entire point.  The band declined to emit a
   derived value; the preference derives a different value, from a wider input
   list, and `--check` re-derives it from committed bytes exactly as before.
   The four annotations below are unchanged and still describe the WHOLE
   assignment's pole gain; `balStabLine` is where the preference's own
   arithmetic is reported. -}
balBandNote : Bool -> Bool -> Bool -> String
balBandNote True _ _ = " — OVERRIDDEN (illegal assignment)"
balBandNote _ True _ = " — TAKEN"
balBandNote _ _ True =
  " — OVERRIDDEN (the committed assignment is not the derived one)"
balBandNote _ _ _ =
  " — not reached (the committed assignment already IS the derived one)"

-- The first gate whose committed row is not its derived row, for the check's
-- message.  A `git diff` of 164 lines does not tell a reader WHICH gate the
-- tool disagrees about, and that is the only fact they need.
balFirstMove : List Place -> Option Place
balFirstMove [] = None
balFirstMove (p :: ps)
  | p.pfrom /= p.pto = Some p
  | otherwise = balFirstMove ps

balMoveLine : List Place -> String
balMoveLine ps = match balFirstMove ps
  None => ""
  Some p =>
    "  first divergence: '\{p.pname}' is committed on row '\{p.pfrom}' but derives to '\{p.pto}'.\n"

{- | The enforcement.  Distinguishes the two ways the budget can be missed,
   because they need different repairs: a packing this command could fix, or
   one gate that has to get faster before any packing can.

   ⚠️ THE SPLIT IS NOW ON WHAT SETS THE FLOOR, NOT ON WHETHER ONE GATE BLOWS THE
   TARGET (S-4, #2216) — and that is a narrowing, deliberately.  Under
   `pole / median` the indivisible-gate branch fired whenever one gate was
   expensive relative to the typical row, which is a fact about the SUITE and
   was the perverse red (`nonpole_speedup.toml`): that case now scores 1.000 and
   is not a refusal at all, because the floor moved up with the gate.

   What survives is the case where it is still true: the floor is a lower bound
   and not always an achievable makespan (500 + three 300s over three rows floors
   at 500 and cannot beat 600), so a miss whose floor is gate-set is a miss
   indivisibility caused.  The message keeps the sentence that made the old one
   worth reading — a reader must leave it knowing the gate has to get FASTER
   (or be split), not just that a number is renamed — while stating honestly
   that a repack may still close part of the gap.  Pointing a reader at
   "rebalance harder" when the answer is "this gate must get faster" costs them
   the whole investigation; pointing them the other way costs the same. -}
balEnforce : List Cand -> List Row -> Option String
balEnforce cs rs
  | balFactorMilli cs rs <= balTargetMilli = None
  | balFloorIsGate cs rs =
    Some
      (stringConcat [
        "medaka gate balance: the emitted assignment misses the pole/floor budget of ",
        balMilli balTargetMilli,
        " (it is ",
        balMilli (balFactorMilli cs rs),
        ").\n",
        "  The floor is '\{(balMaxCand cs).cname}' alone, at \{balSecs (balMaxCand cs).cms}, against a pole of \{balSecs (balPole rs)}.\n",
        "  Gates are indivisible, so the pole can never go below the most expensive\n",
        "  gate, and the rest of this gap is what would not fit around it.  This is\n",
        "  a gate that has to get FASTER (or be split); repacking cannot move the\n",
        "  floor while it stands.\n",
      ])
  | otherwise =
    Some
      (stringConcat [
        "medaka gate balance: the emitted assignment misses the pole/floor budget of ",
        balMilli balTargetMilli,
        " (it is ",
        balMilli (balFactorMilli cs rs),
        ").\n",
        "  No single gate explains it — the floor is \{balSecs (balFloor cs rs)} and no gate costs that\n",
        "  much — so this is the packing: rows within budget exist and the heuristic\n",
        "  did not find them.\n",
      ])

-- ── Writing the assignment back ─────────────────────────────────────────────

-- The new `shard` value for every entry, in FILE ORDER — `other-job` entries
-- included, carrying their sentinel through unchanged, so the list lines up
-- one-for-one with the file's `[[gate]]` blocks and `balSplice` never has to
-- decide which entries it is allowed to skip.
balShardValues : List Gate -> List Place -> List String
balShardValues [] _ = []
balShardValues (g :: gs) ps
  | g.shard == balOtherJob = balOtherJob :: balShardValues gs ps
  | otherwise = balPlaceOf g.name ps :: balShardValues gs ps

balPlaceOf : String -> List Place -> String
balPlaceOf n [] = n
balPlaceOf n (p :: ps)
  | p.pname == n = p.pto
  | otherwise = balPlaceOf n ps

-- Targeted line replacement: every `shard = "…"` line inside a `[[gate]]`
-- block becomes that gate's new value, and every other byte of the file is
-- copied verbatim.  Not a TOML round-trip — `stdlib/toml.mdk` has no
-- serializer, and re-emitting 230 hand-written entries (with their comment
-- blocks) from a parse tree would rewrite far more than the field that
-- changed.
--
-- The `[[shard]]` tables at the foot of the file carry no `shard =` key, and
-- `inGate` goes false at the first of them, so the row definitions are out of
-- reach by construction as well as by key name.
balSplice : List String -> List String -> Result String (List String)
balSplice vals src = balSpliceGo vals src False []

balSpliceGo : List String ->
  List String ->
  Bool ->
  List String ->
  Result String (List String)
balSpliceGo [] [] _ acc = Ok (reverseL acc)
balSpliceGo vs [] _ _ =
  Err
    "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (\{intToString (listLen vs)} unplaced)"
balSpliceGo vs (l :: ls) inGate acc
  | l == "[[gate]]" = balSpliceGo vs ls True (l :: acc)
  | l == "[[shard]]" = balSpliceGo vs ls False (l :: acc)
  | inGate && startsWith "shard = \"" l = match vs
    [] =>
      Err
        "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries"
    v :: rest => balSpliceGo rest ls inGate ("shard = \"\{v}\"" :: acc)
  | otherwise = balSpliceGo vs ls inGate (l :: acc)

-- ── The command ─────────────────────────────────────────────────────────────

data BalArgs = BalArgs {
  registry : Option String,
  baseline : Option String,
  check : Bool,
}

parseBalArgs : List String -> BalArgs -> Result String BalArgs
parseBalArgs [] acc = Ok acc
parseBalArgs ("--registry" :: p :: rest) acc =
  parseBalArgs rest BalArgs { acc | registry = Some p }
parseBalArgs ("--registry" :: []) _ =
  Err "medaka gate balance: --registry needs a path"
parseBalArgs ("--baseline" :: p :: rest) acc =
  parseBalArgs rest BalArgs { acc | baseline = Some p }
parseBalArgs ("--baseline" :: []) _ =
  Err "medaka gate balance: --baseline needs a path"
parseBalArgs ("--check" :: rest) acc =
  parseBalArgs rest BalArgs { acc | check = True }
parseBalArgs (a :: _) _ = Err "medaka gate balance: unexpected argument: \{a}"

-- `<MEDAKA_ROOT>/test/gate_cost_baseline.json` unless --baseline overrides it,
-- the same exe-relative resolution `registryPath` uses.
balBaselinePath : Option String -> String -> String
balBaselinePath (Some p) _ = p
balBaselinePath None root =
  joinPath (joinPath root "test") "gate_cost_baseline.json"

-- Everything that can go wrong before a byte is written, as one `Result`: the
-- projection to print, and the registry text to write.  `ciNewText`'s shape,
-- for `ciCmdBody`'s reason — the mutating form and `--check` must compute the
-- SAME answer and differ only in what they do with it.
balNewText : String -> String -> String -> Result String (String, String)
balNewText regPath regSrc baseSrc = match parseRegistry regSrc
  Err m => Err "medaka gate balance: \{m}"
  Ok gates => match parseShards regSrc
    Err m => Err "medaka gate balance: \{m}"
    Ok shs => match parseCostBaseline baseSrc
      Err m => Err "medaka gate balance: \{m}"
      -- `runs[]` (#2208: jobs/parallel/rowElapsedMs) is LOAD-BEARING as of
      -- this slice: `jobs` is the width of the worker pool each row's makespan
      -- is computed over, and `rowElapsedMs` is what that prediction is
      -- calibrated against.  S-1 landed the read; this is what consumes it.
      Ok base => match parseCostRuns baseSrc
        Err m => Err "medaka gate balance: \{m}"
        Ok runsRead => match balUnknownRows shs gates
          b :: bs =>
            Err
              "medaka gate balance: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace (b :: bs)}"
          [] => match balUncosted base gates
            u :: us =>
              Err
                (stringConcat [
                  "medaka gate balance: \{intToString (listLen (u :: us))} schedulable gate(s) have no row in the cost baseline:\n",
                  joinNl (balIndent (u :: us)),
                  "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n",
                  "  unknown one, and treating it as 0 would pile it onto the lightest row.\n",
                  "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n",
                ])
            [] => match balPinErrors gates shs
              e :: es =>
                Err
                  (stringConcat [
                    "medaka gate balance: \{regPath}: a closed row's membership does not match its declared `pinned_gates`:\n",
                    joinNl (balIndent (e :: es)),
                    "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n",
                    "  nothing off it, so its members are the one `shard` value no cost\n",
                    "  measurement derives.  They are DECLARED in that [[shard]] row's\n",
                    "  `pinned_gates` and checked against the registry in both directions,\n",
                    "  so a hand-moved `shard` cannot be adopted as the new pin.\n",
                    "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n",
                    "  membership is genuinely meant to differ, and say why in its rationale\n",
                    "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n",
                  ])
              [] => balCompute regPath gates shs base runsRead regSrc

balIndent : List String -> List String
balIndent [] = []
balIndent (x :: xs) = "    \{x}" :: balIndent xs

balCompute : String ->
  List Gate ->
  List Shard ->
  List GateCost ->
  List RunRecord ->
  String ->
  Result String (String, String)
balCompute regPath gates shs base runs regSrc =
  let cs = balCands base gates
  -- Cost-descending into BOTH scorings — `balAdd`'s and `balCurrent`'s notes.
  let (_, curRows) = balCurrent (balSortCands cs) (balRows runs shs)
  match balTarget True cs (balRows runs shs)
    Err m => Err m
    Ok (ps, rows) =>
      let illegal = not (balCurrentLegal cs curRows)
      let gains = balPole rows * 100 < balPole curRows * (100 - balMarginPct)
      let moved = balMoved ps > 0
      let label =
        if illegal then
          "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)"
        else if moved then
          "rebalanced"
        else
          "unchanged (the committed assignment is already the derived one)"
      let head = stringConcat
        [
          "medaka gate balance: \{regPath}\n",
          balReport label cs rows ps runs,
          balThinLine base,
          balOosBlock base cs runs,
          balStabLine cs (balRows runs shs) ps rows,
          "  hysteresis: a move needs a pole gain of more than \{intToString balMarginPct}%",
          balBandNote illegal gains moved,
          "\n  budget pole/floor \{balMilli balTargetMilli}",
          if balFactorMilli cs rows <= balTargetMilli then
            " — MET\n"
          else
            " — MISSED\n",
          balMoveLine ps,
          -- Scored against `curRows`, never `rows`: the recorded wall clock came
          -- from the COMMITTED assignment, so comparing it to the DERIVED one
          -- would grade the model against a gate set that has never run.
          "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n",
          joinNl (balCalibLines cs curRows runs),
          "\n",
        ]
      match balEnforce cs rows
        Some m => Err "\{head}\{m}"
        None => match balSplice (balShardValues gates ps) (splitNl regSrc)
          Err m => Err "\{head}\{m}"
          Ok outLines => Ok (head, joinNl outLines)

-- Write only on a real change, like `ciWrite`: an unconditional write touches
-- the file's mtime on every no-op run, and a no-op run is the NORMAL case once
-- the matrix is balanced.
balWrite : String -> String -> String -> String -> <IO> Unit
balWrite regPath regSrc out head
  | out == regSrc =
    putStr
      "\{head}medaka gate balance: \{regPath} already balanced — no shard assignment changed\n"
  | otherwise = match writeFile regPath out
    Err m =>
      emit (Err "\{head}medaka gate balance: cannot write \{regPath}: \{m}")
    Ok _ =>
      putStr
        "\{head}medaka gate balance: rewrote the shard assignments in \{regPath}\n"

-- `--check`: the SAME comparison `balWrite` makes, in memory, with no write —
-- `ciCheckResult`'s shape, and for its reason.  Regenerating first and then
-- shelling out to `git diff` would HEAL an uncommitted hand-edit before the
-- check could see it, and would also fire on an uncommitted edit to a field
-- this command never touches.
balCheckResult : String -> String -> String -> String -> Result String String
balCheckResult regPath regSrc out head
  | out == regSrc =
    Ok "\{head}medaka gate balance: \{regPath} already balanced\n"
  | otherwise =
    Err
      (stringConcat [
        head,
        "medaka gate balance: \{regPath}: the committed shard assignment is not the\n",
        "one the balancer derives from test/gate_cost_baseline.json.  A `shard` field\n",
        "is DERIVED DATA (#2178): it is not hand-editable, and a hand edit that keeps\n",
        "ci.yml self-consistent is exactly what this check exists to catch.  First\n",
        "differing line:\n",
        ciDiffAt (splitNl regSrc) (splitNl out) 1,
        "\nRun 'medaka gate balance' then 'make gen-ci', and commit both.\n",
      ])

balCmdBody : List String -> <IO> Unit
balCmdBody argv = match (parseBalArgs argv BalArgs {
  registry = None,
  baseline = None,
  check = False,
})
  Err m => emit (Err m)
  Ok a =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let regPath = registryPath a.registry
    let basePath = balBaselinePath a.baseline root
    match readFile regPath
      Err m => emit (Err "medaka gate balance: cannot read registry: \{m}")
      Ok regSrc => match readFile basePath
        Err m =>
          emit
            (Err
              "medaka gate balance: cannot read cost baseline \{basePath}: \{m}")
        Ok baseSrc => match balNewText regPath regSrc baseSrc
          Err m => emit (Err m)
          Ok (head, out) =>
            if a.check then
              emit (balCheckResult regPath regSrc out head)
            else
              balWrite regPath regSrc out head

-- ── `gate budget` — #2180's governor (S-5) ──────────────────────────────────
--
-- A required, cheap, TEXT-ONLY gate — no build, `gate verify`'s shape — that
-- reds on any of three clauses:
--
--   (a) a schedulable gate has no cost baseline entry (`balUncosted`'s
--       condition). The sprint contract's literal clause (a) — "a registry
--       entry lacks a cost declaration" — cannot occur: `cost` is a REQUIRED
--       TOML field (`reqStr i "cost" e`) and a registry missing it fails to
--       PARSE, long before this gate runs. `balUncosted`'s "a schedulable
--       gate the packer cannot price" is the state that both can occur and
--       matters.
--   (b) a gate's measured cost has eaten into the tolerance-adjusted timeout
--       its declared `cost` class implies (`timeoutFor`). The class is not
--       free-floating metadata — it is what kills the gate — so "declared
--       class no longer matches reality" is measurable exactly here.
--   (c) the projected `pole/floor` (S-4's metric, `balTargetMilli`) exceeds
--       budget on the SAME assignment `gate balance --check` derives —
--       computed from `balCands`/`balRows`/`balTarget`, which already skip
--       `other-job` gates, so an `other-job` gate's (nonexistent) cost never
--       contributes here either.
--
-- Any clause may be accepted on purpose with a structured, greppable
-- acknowledgment: a trailer line on an AUTHORED commit message in the change
-- under test. There is no PR body in a `merge_group` run, so an authored
-- commit message is the one thing the queue can always see. The `.sh` gate
-- script obtains that text and passes it via `--commit-message`; this module
-- touches no git state itself, so every clause stays testable on plain
-- strings.
--
-- ⚠️ This comment used to say the CHECKED-OUT commit's own message was that
-- text, read with `git log -1 --pretty=%B`, and that being "ordinary git
-- behaviour, not a GitHub-specific API" meant it "needs no separate
-- verification against GitHub policy". That was wrong and is the bug FR-2
-- fixed (review S1-2): it was never a policy question, it was a question
-- about the git state `actions/checkout@v4` produces, and with no `ref:` that
-- is a SYNTHETIC merge commit on both `pull_request` and `merge_group` —
-- GitHub boilerplate, never the author's text. Nothing in THIS module changed
-- (`--commit-message` parsing was always correct); the fix is entirely in how
-- `.github/workflows/ci.yml` and test/diff_compiler_gate_budget.sh obtain the
-- text. See docs/ops/GATE-REGISTRY-DESIGN.md §14 for the measured evidence.

-- The exact trailer a reader pastes: `Gate-Budget-Override: <token>`, one per
-- violation accepted, free text after the token (a human reason) never
-- machine-checked. Multiple lines are read one violation per line.
budgetOverridePrefix : String
budgetOverridePrefix = "Gate-Budget-Override: "

budgetOverrideTokens : String -> List String
budgetOverrideTokens msg = budgetTokensFromLines (splitNl msg)

budgetTokensFromLines : List String -> List String
budgetTokensFromLines [] = []
budgetTokensFromLines (l :: ls)
  | startsWith budgetOverridePrefix (stringTrim l) =
    budgetFirstWord
        (stringTrim (budgetDropPrefix budgetOverridePrefix (stringTrim l)))
      :: budgetTokensFromLines ls
  | otherwise = budgetTokensFromLines ls

budgetDropPrefix : String -> String -> String
budgetDropPrefix pre s = stringSlice (stringLength pre) (stringLength s) s

budgetFirstWord : String -> String
budgetFirstWord s = match splitOnChar ' ' s
  [] => s
  w :: _ => w

budgetAcked : String -> String -> Bool
budgetAcked commitMessage token =
  contains token (budgetOverrideTokens commitMessage)

budgetCountUnacked : String -> List String -> Int
budgetCountUnacked _ [] = 0
budgetCountUnacked commitMessage (t :: ts)
  | budgetAcked commitMessage t = budgetCountUnacked commitMessage ts
  | otherwise = 1 + budgetCountUnacked commitMessage ts

-- ── Clause (a) ───────────────────────────────────────────────────────────────

budgetUncostedNames : List GateCost -> List Gate -> List String
budgetUncostedNames _ [] = []
budgetUncostedNames base (g :: gs)
  | g.shard == balOtherJob = budgetUncostedNames base gs
  | otherwise = match costOf g.run base
    Some _ => budgetUncostedNames base gs
    None => g.name :: budgetUncostedNames base gs

budgetUncostedTokens : List String -> List String
budgetUncostedTokens [] = []
budgetUncostedTokens (n :: ns) = "uncosted:\{n}" :: budgetUncostedTokens ns

budgetUncostedLines : String -> List String -> List String
budgetUncostedLines _ [] = []
budgetUncostedLines commitMessage (n :: ns) =
  let tok = "uncosted:\{n}"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      n, ack,
      " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this",
      " gate gets a sample; the `cost` field is present, the packer just has",
      " no price yet, so there is nothing to declare or split here.",
      " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ", tok,
      "\n"
    ]
    :: budgetUncostedLines commitMessage ns

-- ── Clause (b) ───────────────────────────────────────────────────────────────
--
-- The tolerance is deliberately the SAME constant as clause (c)'s
-- (`balTargetMilli`, 1.125 = 1 + max(S-2's mean |error| 12.0%, bias 12.5%)):
-- one measured slack, used everywhere a noisy estimate is compared to a hard
-- line. `medianMs` can UNDERSTATE a gate's true cost by that much (S-2), so
-- comparing the raw measurement against the raw timeout would let a gate that
-- is actually over its own kill timeout read as compliant on a lucky sample.
budgetTimeoutMs : String -> Int
budgetTimeoutMs cost = timeoutFor 0 cost * 1000

budgetToleratedMs : String -> Int
budgetToleratedMs cost = budgetTimeoutMs cost * 1000 / balTargetMilli

-- Schedulable, COSTED gates whose measured cost exceeds the tolerance-
-- adjusted ceiling for their declared class. Uncosted gates are clause (a)'s
-- alone — never double-reported here.
budgetOverClassGates : List GateCost -> List Gate -> List Gate
budgetOverClassGates _ [] = []
budgetOverClassGates base (g :: gs)
  | g.shard == balOtherJob = budgetOverClassGates base gs
  | otherwise = match costOf g.run base
    None => budgetOverClassGates base gs
    Some ms if ms > budgetToleratedMs g.cost =>
      g :: budgetOverClassGates base gs
    _ => budgetOverClassGates base gs

budgetOverClassTokens : List Gate -> List String
budgetOverClassTokens [] = []
budgetOverClassTokens (g :: gs) =
  "over-class:\{g.name}" :: budgetOverClassTokens gs

-- `timeoutFor`'s coupling is stated inline: re-classing a gate is not a free
-- label change, it changes when CI kills it.
budgetTimeoutRemedy : String
budgetTimeoutRemedy =
  "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate."

budgetOverClassLines : List GateCost -> String -> List Gate -> List String
budgetOverClassLines _ _ [] = []
budgetOverClassLines base commitMessage (g :: gs) =
  -- `ms` is always `Some` here — `budgetOverClassGates` only keeps gates
  -- `costOf` already resolved; the 0 fallback is unreachable, not a real cost.
  let ms = match costOf g.run base
    Some m => m
    None => 0
  let tok = "over-class:\{g.name}"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      "\{g.name} (\{g.cost}, measured \{balSecs ms}, tolerance-adjusted ceiling ",
      balSecs (budgetToleratedMs g.cost),
      " of a \{intToString (timeoutFor 0 g.cost)}s timeout)",
      ack,
      " — remedy: declare a higher `cost` class, split the gate into cheaper",
      " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the",
      " merge-required path. ",
      budgetTimeoutRemedy,
      " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ",
      tok,
      "\n",
    ]
    :: budgetOverClassLines base commitMessage gs

-- ── Clause (c) ───────────────────────────────────────────────────────────────
--
-- The SAME projection `gate balance --check` computes — `balCands` already
-- excludes `other-job` gates from packing entirely, so their (nonexistent)
-- cost cannot move this number by construction.
budgetPoleFactor : List Gate ->
  List Shard ->
  List GateCost ->
  List RunRecord ->
  Result String (Option Int)
budgetPoleFactor gates shs base runs =
  let cs = balCands base gates
  match balTarget True cs (balRows runs shs)
    Err m => Err m
    Ok (_, rows) =>
      let factor = balFactorMilli cs rows
      if factor <= balTargetMilli then Ok None else Ok (Some factor)

budgetPoleFloorLines : String -> Option Int -> List String
budgetPoleFloorLines _ None = []
budgetPoleFloorLines commitMessage (Some factor) =
  let tok = "pole-floor"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      "projected pole/floor \{balMilli factor} exceeds the budget \{balMilli balTargetMilli} (S-4)",
      ack,
      " — remedy: run `medaka gate balance` to see which row or gate needs to",
      " shrink, split the pole gate, or demote a heavy gate to",
      " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ",
      tok,
      "\n",
    ]
    :: []

-- ── Assembling the report ────────────────────────────────────────────────────

budgetIndent : List String -> List String
budgetIndent [] = []
budgetIndent (x :: xs) = "  \{x}" :: budgetIndent xs

budgetSection : String -> List String -> String
budgetSection _ [] = ""
budgetSection title lines =
  "\{title}: \{intToString (listLen lines)}\n\{joinNl (budgetIndent lines)}\n\n"

budgetReport : List GateCost ->
  String ->
  List String ->
  List Gate ->
  Option Int ->
  Result String String
budgetReport base commitMessage uncosted overClass poleFactorOpt =
  let aLines = budgetUncostedLines commitMessage uncosted
  let bLines = budgetOverClassLines base commitMessage overClass
  let cLines = budgetPoleFloorLines commitMessage poleFactorOpt
  let aUnacked =
    budgetCountUnacked commitMessage (budgetUncostedTokens uncosted)
  let bUnacked =
    budgetCountUnacked commitMessage (budgetOverClassTokens overClass)
  let cCount = match poleFactorOpt
    None => 0
    Some _ => 1
  let cUnacked =
    if cCount == 0 then
      0
    else if budgetAcked commitMessage "pole-floor" then
      0
    else
      1
  let total = listLen uncosted + listLen overClass + cCount
  let unacked = aUnacked + bUnacked + cUnacked
  let body = stringConcat [
    budgetSection "no cost baseline entry (clause a)" aLines,
    budgetSection "over declared class, tolerance-adjusted (clause b)" bLines,
    budgetSection "projected pole/floor over budget (clause c)" cLines,
  ]
  if total == 0 then
    Ok "medaka gate budget: OK — 0 violations.\n"
  else if unacked == 0 then
    Ok
      "\{body}medaka gate budget: \{intToString total} violation(s), all acknowledged by commit-message trailer — OK.\n"
  else
    Err
      "\{body}medaka gate budget: FAIL — \{intToString unacked} of \{intToString total} violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n"

budgetOutput : String -> String -> String -> String -> Result String String
budgetOutput regPath regSrc baseSrc commitMessage = match parseRegistry regSrc
  Err m => Err "medaka gate budget: \{m}"
  Ok gates => match parseShards regSrc
    Err m => Err "medaka gate budget: \{m}"
    Ok shs => match parseCostBaseline baseSrc
      Err m => Err "medaka gate budget: \{m}"
      Ok base => match parseCostRuns baseSrc
        Err m => Err "medaka gate budget: \{m}"
        Ok runs => match balUnknownRows shs gates
          u :: us =>
            Err
              "medaka gate budget: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace (u :: us)}\n"
          [] =>
            let uncosted = budgetUncostedNames base gates
            let overClass = budgetOverClassGates base gates
            match budgetPoleFactor gates shs base runs
              Err m => Err "medaka gate budget: \{m}\n"
              Ok poleFactorOpt =>
                budgetReport base commitMessage uncosted overClass poleFactorOpt

data BudgetArgs = BudgetArgs {
  registry : Option String,
  baseline : Option String,
  commitMessage : String,
}

-- `withStrictDash` (F1, review finding, #2355): an undeclared `-x` used to
-- fall through as a positional pre-migration; base rejected any leading-`-`
-- token here, so this restores that floor via the S-5 knob.
budgetArgSpec : ArgSpec
budgetArgSpec =
  withStrictDash
    (spec "gate budget" [
      value ["--registry"] "PATH" "override the gate registry path",
      value ["--baseline"] "PATH" "override the cost baseline path",
      value
        ["--commit-message"]
        "TEXT"
        "commit message to scan for a Gate-Budget-Override trailer",
    ])

budgetMissingValue : List (String, String)
budgetMissingValue = [
  ("--registry", "medaka gate budget: --registry needs a path"),
  ("--baseline", "medaka gate budget: --baseline needs a path"),
  ("--commit-message", "medaka gate budget: --commit-message needs a value"),
]

budgetCommitMessage : Args -> String
budgetCommitMessage a = match flagValue "--commit-message" a
  Some v => v
  None => ""

-- `budget`, like `verify`, takes no positionals — a leftover token is
-- rejected the same way an unclaimed flag would be.
parseBudgetArgs : List String -> Result String BudgetArgs
parseBudgetArgs argv = match parseArgs budgetArgSpec argv
  Err m => Err (missingValueOverride budgetArgSpec budgetMissingValue m)
  Ok a => match a.positionals
    [] => Ok BudgetArgs {
      registry = flagValue "--registry" a,
      baseline = flagValue "--baseline" a,
      commitMessage = budgetCommitMessage a,
    }
    p :: _ => Err (unknownFlagMessage budgetArgSpec p)

budgetCmdBody : List String -> <IO> Unit
budgetCmdBody argv = match parseBudgetArgs argv
  Err m => emit (Err m)
  Ok a =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let regPath = registryPath a.registry
    let basePath = balBaselinePath a.baseline root
    match readFile regPath
      Err m => emit (Err "medaka gate budget: cannot read registry: \{m}")
      Ok regSrc => match readFile basePath
        Err m =>
          emit
            (Err
              "medaka gate budget: cannot read cost baseline \{basePath}: \{m}")
        Ok baseSrc => emit (budgetOutput regPath regSrc baseSrc a.commitMessage)

-- ── Properties ──────────────────────────────────────────────────────────────

prop "a bare selector token is name: sugar" (n : Int) =
  parseSelector (intToString n) == Ok (SelName (intToString n))

prop "an explicit name: selector agrees with the bare form" (n : Int) =
  parseSelector ("name:" ++ intToString n) == parseSelector (intToString n)

prop "a literal glob matches itself and nothing longer" (n : Int) =
  globMatch (intToString n) (intToString n)
    && not (globMatch (intToString n) (intToString n ++ "x"))

prop "a trailing * matches any suffix" (n : Int) =
  globMatch "g*" ("g" ++ intToString n)
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "getBool" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "readDeps" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "Trailing" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "withTrailing" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "unknownFlagMessage" false) (mem "missingValueMessage" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "GateCost" false) (mem "RunRecord" false) (mem "baselineKey" false) (mem "costOf" false) (mem "costRowOf" false) (mem "gateSetDigest" false) (mem "latestRunForShard" false) (mem "packStat" false) (mem "parseCostBaseline" false) (mem "parseCostRuns" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "maxI" false) (mem "minI" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tiers" (TyApp (TyCon "List") (TyCon "String"))) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readGateEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readGateEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGateEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "tiers"))) (EVar "e"))) (ELam ((PVar "tiers")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tiers" (EVar "tiers")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DData Public "Shard" () ((variant "Shard" (ConNamed (field "name" (TyCon "String")) (field "fullCores" (TyCon "Bool")) (field "wasmArm" (TyCon "Bool")) (field "rationale" (TyCon "String")) (field "pinned" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "shardStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardBool" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "shardBool" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Ok") (EVar "b"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required boolean field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "shardArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readShard" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShard" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "shard"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readShardEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readShardEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShardEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "full_cores"))) (EVar "e"))) (ELam ((PVar "fullCores")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "wasm_arm"))) (EVar "e"))) (ELam ((PVar "wasmArm")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "rationale"))) (EVar "e"))) (ELam ((PVar "rationale")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "shardArr") (EVar "i")) (ELit (LString "pinned_gates"))) (EVar "e"))) (ELam ((PVar "pinned")) (EApp (EVar "Ok") (ERecordCreate "Shard" ((fa "name" (EVar "name")) (fa "fullCores" (EVar "fullCores")) (fa "wasmArm" (EVar "wasmArm")) (fa "rationale" (EVar "rationale")) (fa "pinned" (EVar "pinned"))))))))))))))))
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
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "anyTierMatch") (EVar "p")) (EFieldAccess (EVar "g") "tiers")))
(DTypeSig true "anyTierMatch" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyTierMatch" (PWild (PList)) (EVar "False"))
(DFunDef false "anyTierMatch" ((PVar "p") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "t")) (EVar "True") (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EApp (EVar "tierPartOf") (EVar "t"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "anyTierMatch") (EVar "p")) (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "tierPartOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tierPartOf" ((PVar "tok")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "tok")) (arm (PList) () (EVar "tok")) (arm (PCons (PVar "t") PWild) () (EVar "t"))))
(DTypeSig true "modePartOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modePartOf" ((PVar "tok")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EApp (EVar "tierPartOf") (EVar "tok")))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (EApp (EVar "stringLength") (EVar "tok"))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))))))
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
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "baselineKey")) (EApp (EVar "JString") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "tiers")))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig false "shardJson" (TyFun (TyCon "Shard") (TyCon "Json")))
(DFunDef false "shardJson" ((PVar "sh")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "name"))) (ETuple (ELit (LString "full_cores")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "fullCores"))) (ETuple (ELit (LString "wasm_arm")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "wasmArm"))) (ETuple (ELit (LString "rationale")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "rationale"))) (ETuple (ELit (LString "pinned_gates")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "sh") "pinned")))))))
(DTypeSig true "renderShardsJson" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShardsJson" ((PVar "shs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "shardJson")) (EVar "shs")))))
(DTypeSig false "boolWord" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolWord" ((PVar "b")) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig true "renderShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShards" ((PList)) (ELit (LString "")))
(DFunDef false "renderShards" ((PCons (PVar "sh") (PVar "shs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString ": full_cores="))) (EApp (EVar "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "fullCores")))) (ELit (LString " wasm_arm="))) (EApp (EVar "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "wasmArm")))) (ELit (LString " rationale="))) (EApp (EVar "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString " pinned_gates=["))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "sh") "pinned")))) (ELit (LString "]\n"))) (EApp (EVar "renderShards") (EVar "shs"))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate reach   [<changed-path>...] [--paths-from <file>] [--json]\n")) (ELit (LString "                      [--registry <path>] [--root <path>]\n")) (ELit (LString "  medaka gate ci      [--check] [--registry <path>] [--workflow <path>]\n")) (ELit (LString "  medaka gate balance [--check] [--registry <path>] [--baseline <path>]\n")) (ELit (LString "  medaka gate budget  [--registry <path>] [--baseline <path>]\n")) (ELit (LString "                      [--commit-message <text>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      a RUN of this gate: merge | nightly | ondemand, optionally\n")) (ELit (LString "                   /<mode> (the invocation delta, e.g. nightly/PERF_DEEP=1).\n")) (ELit (LString "                   A gate can have several; the glob matches a whole token or\n")) (ELit (LString "                   its tier part, so tier:nightly selects every mode.\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` only:\n")) (ELit (LString "  --check            derive the assignment in memory and report whether the\n")) (ELit (LString "                     committed one matches it; write nothing\n")) (ELit (LString "  --baseline <path>  read this cost baseline instead of\n")) (ELit (LString "                     <MEDAKA_ROOT>/test/gate_cost_baseline.json\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` CHOOSES each gate's `shard` row from the registry's own\n")) (ELit (LString "constraints plus the measured cost baseline, and rewrites the `shard = \"...\"`\n")) (ELit (LString "lines in test/gates.toml in place. A full_cores row is CLOSED: its members\n")) (ELit (LString "are declared by that [[shard]] row's `pinned_gates` and checked in both\n")) (ELit (LString "directions, so they are neither packed nor hand-assignable. A gate needing\n")) (ELit (LString "wasm-tools/node only lands on a\n")) (ELit (LString "row with wasm_arm = true. It refuses rather than pack from a missing cost,\n")) (ELit (LString "and fails when the assignment it would emit misses its pole/floor budget.\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, no two entries\n")) (ELit (LString "share a `name`, and every entry's `cost` and `tiers` are well formed.\n")) (ELit (LString "Exits nonzero on any violation. It checks the SHAPE of `tiers`, not\n")) (ELit (LString "whether it agrees with the workflows — that is\n")) (ELit (LString "test/diff_compiler_tier_drift.sh, which reads the workflow YAML.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`.\n")) (ELit (LString "\n")) (ELit (LString "  --check            ci: compare only — compute the generated text and\n")) (ELit (LString "                     compare it IN MEMORY to the file on disk, writing\n")) (ELit (LString "                     nothing. Exit 0 when they agree, 1 with the first\n")) (ELit (LString "                     differing line when they do not. This is the drift\n")) (ELit (LString "                     check; regenerating first would heal an uncommitted\n")) (ELit (LString "                     hand-edit before any diff could see it, and diffing\n")) (ELit (LString "                     the whole file would also fire on an edit OUTSIDE\n")) (ELit (LString "                     the generated region.\n")) (ELit (LString "\n")) (ELit (LString "The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")) (ELit (LString "\n")) (ELit (LString "`gate reach <changed-path>...` is the QUEUE's project scoping (#2179):\n")) (ELit (LString "which projects must run their gates for an entry touching those paths.\n")) (ELit (LString "A path under <project>/ selects that project, plus every project whose\n")) (ELit (LString "medaka.toml [dependencies] reaches it, plus the owning project of every\n")) (ELit (LString "gate whose `corpus` names a selected project. An empty list, a compiler/\n")) (ELit (LString "or stdlib/ path, and any path no project directory claims all FAIL OPEN\n")) (ELit (LString "to every project: this command never answers `nothing`.\n")) (ELit (LString "\n")) (ELit (LString "`gate budget` is #2180's governor: text-only, no build. Reds when (a) a\n")) (ELit (LString "schedulable gate has no cost baseline entry, (b) a gate's measured cost\n")) (ELit (LString "has eaten into the tolerance-adjusted timeout its declared `cost` class\n")) (ELit (LString "implies, or (c) the projected pole/floor (the same number `gate balance\n")) (ELit (LString "--check` derives) exceeds S-4's budget. Any violation may be accepted on\n")) (ELit (LString "purpose with a `Gate-Budget-Override: <token>` trailer on the commit\n")) (ELit (LString "message (there is no PR body in a merge_group run) — the failing gate\n")) (ELit (LString "prints the exact trailer to paste.\n")) (ELit (LString "\n")) (ELit (LString "  --commit-message <text>  budget: the commit message to scan for\n")) (ELit (LString "                     `Gate-Budget-Override:` trailers. Omit for none.\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "shards" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "missingValueOverride" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingValueOverride" (PWild (PList) (PVar "msg")) (EVar "msg"))
(DFunDef false "missingValueOverride" ((PVar "sp") (PCons (PTuple (PVar "flg") (PVar "custom")) (PVar "rest")) (PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "sp")) (EVar "flg"))) (EVar "custom") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "sp")) (EVar "rest")) (EVar "msg"))))
(DTypeSig false "listArgSpec" (TyCon "ArgSpec"))
(DFunDef false "listArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate list"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit machine-readable JSON"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--shards")))) (ELit (LString "print each entry's shard placement"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path")))))))
(DTypeSig false "listMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "listMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate list: --registry needs a path")))))
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs"))))
(DFunDef false "parseListArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "listArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "listArgSpec")) (EVar "listMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EApp (EVar "Ok") (ERecordCreate "ListArgs" ((fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "shards" (EApp (EApp (EVar "flag") (ELit (LString "--shards"))) (EVar "a"))) (fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "selectors" (EFieldAccess (EVar "a") "positionals"))))))))
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
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EVar "parseListArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EIf (EFieldAccess (EVar "a") "shards") (EApp (EApp (EApp (EVar "shardsOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path"))))))))))))))
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
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run|verify|explain|reach|ci|balance|budget> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EVar "verifyCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) (PVar "rest"))) (EApp (EVar "explainCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "reach")) (PVar "rest"))) (EApp (EVar "reachCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "ci")) (PVar "rest"))) (EApp (EVar "ciCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "balance")) (PVar "rest"))) (EApp (EVar "balCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "budget")) (PVar "rest"))) (EApp (EVar "budgetCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: list, run, verify, explain, reach, ci, balance, budget)"))))))
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
(DTypeSig false "runArgSpec" (TyCon "ArgSpec"))
(DFunDef false "runArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate run"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--dry-run")))) (ELit (LString "print what would run, without running it"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the machine-readable timing report"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--no-stale-check")))) (ELit (LString "skip the stale-oracle refusal"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--report")))) (ELit (LString "PATH"))) (ELit (LString "write the timing report here"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--timeout")))) (ELit (LString "N"))) (ELit (LString "per-gate timeout, in seconds"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--jobs")))) (ELit (LString "N"))) (ELit (LString "worker count (reported only; gates run sequentially)")))))))
(DTypeSig false "runMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "runMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate run: --registry needs a path"))) (ETuple (ELit (LString "--report")) (ELit (LString "medaka gate run: --report needs a path"))) (ETuple (ELit (LString "--timeout")) (ELit (LString "medaka gate run: --timeout needs a number of seconds"))) (ETuple (ELit (LString "--jobs")) (ELit (LString "medaka gate run: --jobs needs a number")))))
(DTypeSig false "runTimeout" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "runTimeout" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--timeout"))) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (ELit (LInt 0)))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --timeout needs a whole number of seconds, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n")))))))
(DTypeSig false "runJobs" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "runJobs" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--jobs"))) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (ELit (LInt 1)))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --jobs needs a whole number, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n")))))))
(DTypeSig false "parseRunArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunArgs"))))
(DFunDef false "parseRunArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "runArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "runArgSpec")) (EVar "runMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EVar "runTimeout") (EVar "a")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "timeoutSecs")) () (EApp (EApp (EVar "map") (ELam ((PVar "jobs")) (ERecordCreate "RunArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "selectors" (EFieldAccess (EVar "a") "positionals")) (fa "dryRun" (EApp (EApp (EVar "flag") (ELit (LString "--dry-run"))) (EVar "a"))) (fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "report" (EApp (EApp (EVar "flagValue") (ELit (LString "--report"))) (EVar "a"))) (fa "timeoutSecs" (EVar "timeoutSecs")) (fa "jobs" (EVar "jobs")) (fa "noStaleCheck" (EApp (EApp (EVar "flag") (ELit (LString "--no-stale-check"))) (EVar "a"))))))) (EApp (EVar "runJobs") (EVar "a"))))))))
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
(DFunDef false "runRunCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseRunArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectFor") (EVar "path")) (EFieldAccess (EVar "a") "selectors")) (EVar "sels")) (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "gs")) () (EApp (EApp (EVar "runSelected") (EVar "a")) (EVar "gs")))))))))))))
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
(DTypeSig false "nameCharOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nameCharOk" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EVar "True") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z")))) (EVar "True") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "_"))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "nameLeadOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nameLeadOk" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EVar "False") (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "nameCharOk") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "nameCharsOk" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nameCharsOk" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EVar "nameCharOk") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EApp (EApp (EApp (EVar "nameCharsOk") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstBadChar" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "firstBadChar" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "(none)")) (EIf (EApp (EVar "not") (EApp (EVar "nameCharOk") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))) (ELit (LString "' at position "))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstBadChar") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unsafeName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unsafeName" ((PVar "kind") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "(empty): a ")) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " name is empty — it cannot be selected, quoted or generated")))) (EIf (EApp (EVar "not") (EApp (EVar "nameLeadOk") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "n")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " name must start with a letter, a digit or '_'")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "nameCharsOk") (EVar "n")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "n")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " name contains "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "firstBadChar") (EVar "n")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "n"))))) (ELit (LString " — allowed characters are letters, digits, '_', '.' and '/' (a name is emitted into ci.yml and re-read as an unquoted shell word)")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "unsafeGateNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unsafeGateNames" ((PList)) (EListLit))
(DFunDef false "unsafeGateNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "unsafeName") (ELit (LString "gate"))) (EFieldAccess (EVar "g") "name")) (EApp (EVar "unsafeGateNames") (EVar "gs"))))
(DTypeSig false "unsafeShardNames" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unsafeShardNames" ((PList)) (EListLit))
(DFunDef false "unsafeShardNames" ((PCons (PVar "s") (PVar "ss"))) (EBinOp "++" (EApp (EApp (EVar "unsafeName") (ELit (LString "shard row"))) (EFieldAccess (EVar "s") "name")) (EApp (EVar "unsafeShardNames") (EVar "ss"))))
(DTypeSig false "unsafeNameViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unsafeNameViolations" ((PVar "gates") (PVar "shs")) (EBinOp "++" (EApp (EVar "unsafeGateNames") (EVar "gates")) (EApp (EVar "unsafeShardNames") (EVar "shs"))))
(DTypeSig false "costClassOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "costClassOk" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString "cheap"))) (EBinOp "==" (EVar "c") (ELit (LString "medium")))) (EBinOp "==" (EVar "c") (ELit (LString "heavy")))))
(DTypeSig false "invalidCostViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidCostViolations" ((PList)) (EListLit))
(DFunDef false "invalidCostViolations" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "costClassOk") (EFieldAccess (EVar "g") "cost")) (EApp (EVar "invalidCostViolations") (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": cost '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString "' is not one of cheap/medium/heavy"))) (EApp (EVar "invalidCostViolations") (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tierNameOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "tierNameOk" ((PVar "t")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "t") (ELit (LString "merge"))) (EBinOp "==" (EVar "t") (ELit (LString "nightly")))) (EBinOp "==" (EVar "t") (ELit (LString "ondemand")))))
(DTypeSig false "hasModeSep" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasModeSep" ((PVar "tok")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "tok")) (EApp (EVar "stringLength") (EApp (EVar "tierPartOf") (EVar "tok")))))
(DTypeSig false "tierTokenErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tierTokenErrors" ((PVar "gname") (PVar "tok")) (EIf (EApp (EVar "not") (EApp (EVar "tierNameOk") (EApp (EVar "tierPartOf") (EVar "tok")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gname"))) (ELit (LString ": run token '"))) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' — tier '"))) (EApp (EVar "display") (EApp (EVar "tierPartOf") (EVar "tok")))) (ELit (LString "' is not one of merge/nightly/ondemand")))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "tierPartOf") (EVar "tok")) (ELit (LString "ondemand"))) (EApp (EVar "hasModeSep") (EVar "tok"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gname"))) (ELit (LString ": run token '"))) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' — 'ondemand' cannot carry a mode; nothing invokes the gate, so there is no invocation for a mode to differ from")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tierTokensErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tierTokensErrors" (PWild (PList)) (EListLit))
(DFunDef false "tierTokensErrors" ((PVar "gname") (PCons (PVar "t") (PVar "ts"))) (EBinOp "++" (EApp (EApp (EVar "tierTokenErrors") (EVar "gname")) (EVar "t")) (EApp (EApp (EVar "tierTokensErrors") (EVar "gname")) (EVar "ts"))))
(DTypeSig false "hasOndemand" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasOndemand" ((PList)) (EVar "False"))
(DFunDef false "hasOndemand" ((PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "tierPartOf") (EVar "t")) (ELit (LString "ondemand"))) (EApp (EVar "hasOndemand") (EVar "ts"))))
(DTypeSig false "strictlyAscending" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "strictlyAscending" ((PList)) (EVar "True"))
(DFunDef false "strictlyAscending" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "strictlyAscending" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EBinOp "&&" (EBinOp "<" (EVar "a") (EVar "b")) (EApp (EVar "strictlyAscending") (EBinOp "::" (EVar "b") (EVar "rest")))))
(DTypeSig false "invalidTiersViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidTiersViolations" ((PList)) (EListLit))
(DFunDef false "invalidTiersViolations" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EVar "gateTiersErrors") (EVar "g")) (EApp (EVar "invalidTiersViolations") (EVar "gs"))))
(DTypeSig false "gateTiersErrors" (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gateTiersErrors" ((PVar "g")) (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "tiers")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers is empty — every gate has at least one run; a gate nothing invokes is tiers = [\"ondemand\"]")))) (EIf (EApp (EVar "not") (EApp (EVar "strictlyAscending") (EFieldAccess (EVar "g") "tiers"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EFieldAccess (EVar "g") "tiers")))) (ELit (LString " is not sorted and unique")))) (EIf (EBinOp "&&" (EApp (EVar "hasOndemand") (EFieldAccess (EVar "g") "tiers")) (EBinOp ">" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "tiers")) (ELit (LInt 1)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EFieldAccess (EVar "g") "tiers")))) (ELit (LString " mixes 'ondemand' with a real run — 'ondemand' means nothing invokes this gate, so it appears alone or not at all")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "tierTokensErrors") (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "tiers")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))) (ETuple (ELit (LString "unsafe entry names")) (EApp (EApp (EVar "unsafeNameViolations") (EVar "gates")) (EVar "shs"))) (ETuple (ELit (LString "invalid cost class")) (EApp (EVar "invalidCostViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid tiers")) (EApp (EVar "invalidTiersViolations") (EVar "gates"))))))))))
(DTypeSig false "renderClass" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "OK    ")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": 0\n"))))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PVar "vs"))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "vs")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "names"))) (ELit (LString "\n"))))))
(DTypeSig false "renderClasses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderClasses" ((PList)) (ELit (LString "")))
(DFunDef false "renderClasses" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "++" (EApp (EVar "renderClass") (EVar "c")) (EApp (EVar "renderClasses") (EVar "cs"))))
(DTypeSig false "totalViolations" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "totalViolations" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalViolations" ((PCons (PTuple PWild (PVar "vs")) (PVar "cs"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "vs")) (EApp (EVar "totalViolations") (EVar "cs"))))
(DTypeSig false "verifyOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "verifyOutput" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EApp (EApp (EVar "verifyClasses") (EVar "root")) (EVar "gates")) (EVar "shs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "classes")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "totalViolations") (EVar "classes"))) (DoLet false false (PVar "body") (EApp (EVar "renderClasses") (EVar "classes"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: OK — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries, 0 violations.\n"))))) (EApp (EVar "Err") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: FAIL — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " violation(s) across "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries.\n")))))))))))
(DData Private "VerifyArgs" () ((variant "VerifyArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "verifyArgSpec" (TyCon "ArgSpec"))
(DFunDef false "verifyArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate verify"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path")))))))
(DTypeSig false "verifyMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "verifyMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate verify: --registry needs a path")))))
(DTypeSig false "parseVerifyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "VerifyArgs"))))
(DFunDef false "parseVerifyArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "verifyArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "verifyArgSpec")) (EVar "verifyMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "VerifyArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))))))) (arm (PCons (PVar "p") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "verifyArgSpec")) (EVar "p"))))))))
(DTypeSig false "verifyCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseVerifyArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "shs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EVar "emit") (EApp (EApp (EApp (EVar "verifyOutput") (EVar "root")) (EVar "gates")) (EVar "shs"))))))))))))))))
(DTypeSig true "blastRadiusPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "blastRadiusPrefixes" () (EListLit (ELit (LString "compiler/support/*")) (ELit (LString "compiler/entries/*")) (ELit (LString "stdlib/*")) (ELit (LString "runtime/*"))))
(DTypeSig false "blastHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "blastHit" ((PList) PWild) (EVar "None"))
(DFunDef false "blastHit" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "path")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "blastHit") (EVar "ps")) (EVar "path"))))
(DTypeSig true "isProsePath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isProsePath" ((PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test/"))) (EVar "p")) (EVar "False") (EIf (EBinOp "==" (EVar "p") (ELit (LString "docs/spec/SYNTAX.md"))) (EVar "False") (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "docs/guide/"))) (EVar "p")) (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p"))) (EVar "False") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "docs/"))) (EVar "p")) (EVar "True") (EIf (EBinOp "==" (EVar "p") (ELit (LString "LICENSE"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "LICENSE."))) (EVar "p")) (EVar "True") (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p")) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
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
(DFunDef false "matchedFields" ((PVar "tok") (PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "fieldHit") (ELit (LString "run"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "run"))) (EApp (EApp (EVar "fieldHit") (ELit (LString "name"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "name")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "area"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "area")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "project"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "project")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "tiers"))) (EApp (EApp (EVar "anyEqStr") (EVar "tok")) (EFieldAccess (EVar "g") "tiers")))))
(DTypeSig false "anyEqStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyEqStr" (PWild (PList)) (EVar "False"))
(DFunDef false "anyEqStr" ((PVar "tok") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EVar "tok") (EVar "x")) (EApp (EApp (EVar "anyEqStr") (EVar "tok")) (EVar "xs"))))
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
(DTypeSig false "explainArgSpec" (TyCon "ArgSpec"))
(DFunDef false "explainArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate explain"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--prose")))) (ELit (LString "print only the PROSE/NONDOC verdict")))))))
(DTypeSig false "explainMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "explainMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate explain: --registry needs a path")))))
(DTypeSig false "parseExplainArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ExplainArgs"))))
(DFunDef false "parseExplainArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "explainArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "explainArgSpec")) (EVar "explainMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "ExplainArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "path" (EVar "None")) (fa "prose" (EApp (EApp (EVar "flag") (ELit (LString "--prose"))) (EVar "a"))))))) (arm (PList (PVar "p")) () (EApp (EVar "Ok") (ERecordCreate "ExplainArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "path" (EApp (EVar "Some") (EVar "p"))) (fa "prose" (EApp (EApp (EVar "flag") (ELit (LString "--prose"))) (EVar "a"))))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "medaka gate explain: expected exactly one <path> argument"))))))))
(DTypeSig false "explainCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "explainCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseExplainArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "path") (arm (PCon "None") () (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate explain <path> [--prose] [--registry <path>]"))))) (arm (PCon "Some" (PVar "tok")) () (EIf (EFieldAccess (EVar "a") "prose") (EApp (EVar "putStr") (EApp (EVar "proseVerdict") (EVar "tok"))) (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EVar "putStr") (EApp (EApp (EVar "explainOutput") (EVar "tok")) (EVar "gates")))))))))))))))
(DTypeSig false "compilerProject" (TyCon "String"))
(DFunDef false "compilerProject" () (ELit (LString "compiler")))
(DTypeSig false "directHits" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "directHits" ((PList) PWild) (EListLit))
(DFunDef false "directHits" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EBinOp "==" (EVar "p") (EVar "compilerProject")) (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path")) (EIf (EApp (EApp (EVar "underDir") (EVar "p")) (EVar "path")) (EBinOp "::" (EVar "p") (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatHits" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "concatHits" (PWild (PList)) (EListLit))
(DFunDef false "concatHits" ((PVar "univ") (PCons (PVar "path") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "directHits") (EVar "univ")) (EVar "path")) (EApp (EApp (EVar "concatHits") (EVar "univ")) (EVar "rest"))))
(DTypeSig false "allHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "allHit" (PWild (PList)) (EVar "True"))
(DFunDef false "allHit" ((PVar "univ") (PCons (PVar "path") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EApp (EApp (EVar "directHits") (EVar "univ")) (EVar "path")))) (EApp (EApp (EVar "allHit") (EVar "univ")) (EVar "rest"))))
(DTypeSig true "reachIsFailOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "reachIsFailOpen" ((PVar "univ") (PVar "paths")) (EIf (EApp (EVar "isEmptyStrs") (EVar "paths")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "not") (EApp (EApp (EVar "allHit") (EVar "univ")) (EVar "paths"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyIn" ((PList) PWild) (EVar "False"))
(DFunDef false "anyIn" ((PCons (PVar "x") (PVar "xs")) (PVar "sel")) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "x")) (EVar "sel")) (EApp (EApp (EVar "anyIn") (EVar "xs")) (EVar "sel"))))
(DTypeSig false "edgeAdds" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "edgeAdds" ((PList) PWild) (EListLit))
(DFunDef false "edgeAdds" ((PCons (PTuple (PVar "lhs") (PVar "rhs")) (PVar "rest")) (PVar "sel")) (EIf (EApp (EApp (EVar "anyIn") (EVar "rhs")) (EVar "sel")) (EBinOp "::" (EVar "lhs") (EApp (EApp (EVar "edgeAdds") (EVar "rest")) (EVar "sel"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "edgeAdds") (EVar "rest")) (EVar "sel")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "closeGo" ((PVar "fuel") (PVar "deps") (PVar "ces") (PVar "sel")) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EVar "sel") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nxt") (EApp (EVar "sortUniqS") (EBinOp "++" (EBinOp "++" (EVar "sel") (EApp (EApp (EVar "edgeAdds") (EVar "deps")) (EVar "sel"))) (EApp (EApp (EVar "edgeAdds") (EVar "ces")) (EVar "sel"))))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "nxt")) (EApp (EVar "listLen") (EVar "sel"))) (EVar "sel") (EApp (EApp (EApp (EApp (EVar "closeGo") (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "deps")) (EVar "ces")) (EVar "nxt"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "reachProjects" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reachProjects" ((PVar "univ") (PVar "deps") (PVar "ces") (PVar "paths")) (EBlock (DoLet false false (PVar "all") (EApp (EVar "sortUniqS") (EVar "univ"))) (DoExpr (EIf (EApp (EApp (EVar "reachIsFailOpen") (EVar "all")) (EVar "paths")) (EVar "all") (EApp (EApp (EApp (EApp (EVar "closeGo") (EBinOp "+" (EApp (EVar "listLen") (EVar "all")) (ELit (LInt 1)))) (EVar "deps")) (EVar "ces")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "concatHits") (EVar "all")) (EVar "paths"))))))))
(DTypeSig true "projectUniverse" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectUniverse" ((PVar "gs")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (ELam ((PVar "g")) (EFieldAccess (EVar "g") "project"))) (EVar "gs"))))
(DTypeSig true "corpusProjectEdges" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "corpusProjectEdges" (PWild (PList)) (EListLit))
(DFunDef false "corpusProjectEdges" ((PVar "univ") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "contains") (EVar "c")) (EVar "univ")))) (EFieldAccess (EVar "g") "corpus"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "corpusProjectEdges") (EVar "univ")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "cs")) (EVar "rest") (EBinOp "::" (ETuple (EFieldAccess (EVar "g") "project") (EVar "cs")) (EVar "rest"))))))
(DTypeSig false "projectForRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "projectForRoot" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "projectForRoot" ((PVar "root") (PCons (PVar "q") (PVar "qs")) (PVar "dr")) (EIf (EBinOp "==" (EApp (EVar "canonicalizePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "q"))) (EApp (EVar "canonicalizePath") (EVar "dr"))) (EApp (EVar "Some") (EVar "q")) (EApp (EApp (EApp (EVar "projectForRoot") (EVar "root")) (EVar "qs")) (EVar "dr"))))
(DTypeSig false "depRootsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "depRootsOf" ((PList)) (EListLit))
(DFunDef false "depRootsOf" ((PCons (PTuple PWild (PVar "r")) (PVar "rest"))) (EBinOp "::" (EVar "r") (EApp (EVar "depRootsOf") (EVar "rest"))))
(DTypeSig false "depProjectsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "depProjectsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "depProjectsGo" ((PVar "root") (PVar "univ") (PCons (PVar "dr") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "projectForRoot") (EVar "root")) (EVar "univ")) (EVar "dr")) (arm (PCon "Some" (PVar "q")) () (EBinOp "::" (EVar "q") (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EVar "rest")))))
(DTypeSig false "depProjectsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "depProjectsOf" ((PVar "root") (PVar "univ") (PVar "p")) (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EApp (EVar "depRootsOf") (EApp (EVar "readDeps") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "p")))))))
(DTypeSig false "projectDepEdges" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "projectDepEdges" (PWild PWild (PList)) (EListLit))
(DFunDef false "projectDepEdges" ((PVar "root") (PVar "univ") (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EApp (EVar "depProjectsOf") (EVar "root")) (EVar "univ")) (EVar "p"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "projectDepEdges") (EVar "root")) (EVar "univ")) (EVar "ps"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "ds")) (EVar "rest") (EBinOp "::" (ETuple (EVar "p") (EVar "ds")) (EVar "rest"))))))
(DTypeSig false "renderProjects" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderProjects" ((PList)) (ELit (LString "")))
(DFunDef false "renderProjects" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "\n"))) (EApp (EVar "renderProjects") (EVar "ps"))))
(DTypeSig false "reachJson" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "reachJson" ((PVar "failOpen") (PVar "paths") (PVar "projects")) (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "projects")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EVar "projects")))) (ETuple (ELit (LString "failOpen")) (EApp (EVar "JBool") (EVar "failOpen"))) (ETuple (ELit (LString "changed")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EVar "paths"))))))) (ELit (LString "\n"))))
(DData Private "ReachArgs" () ((variant "ReachArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "root" (TyApp (TyCon "Option") (TyCon "String"))) (field "json" (TyCon "Bool")) (field "pathsFrom" (TyApp (TyCon "Option") (TyCon "String"))) (field "paths" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reachArgSpec" (TyCon "ArgSpec"))
(DFunDef false "reachArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "withTrailing") (EVar "TrailingAfterSeparator")) (EApp (EApp (EVar "spec") (ELit (LString "gate reach"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--root")))) (ELit (LString "PATH"))) (ELit (LString "override MEDAKA_ROOT"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--paths-from")))) (ELit (LString "PATH"))) (ELit (LString "read changed paths from a file"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit JSON"))))))))
(DTypeSig false "parseReachArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ReachArgs"))))
(DFunDef false "parseReachArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "reachArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EVar "reachRewriteErr") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EApp (EVar "Ok") (ERecordCreate "ReachArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "root" (EApp (EApp (EVar "flagValue") (ELit (LString "--root"))) (EVar "a"))) (fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "pathsFrom" (EApp (EApp (EVar "flagValue") (ELit (LString "--paths-from"))) (EVar "a"))) (fa "paths" (EBinOp "++" (EFieldAccess (EVar "a") "positionals") (EFieldAccess (EVar "a") "rest")))))))))
(DTypeSig false "reachRewriteErr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reachRewriteErr" ((PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--registry")))) (ELit (LString "medaka gate reach: --registry needs a path")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--root")))) (ELit (LString "medaka gate reach: --root needs a path")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--paths-from")))) (ELit (LString "medaka gate reach: --paths-from needs a path")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "msg")) (ELit (LInt 1)))) (EVar "msg")) (ELit (LString "; use `--` before a path starting with '-')"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nonBlankPaths" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonBlankPaths" ((PVar "xs")) (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EVar "xs")))
(DTypeSig false "reachPaths" (TyFun (TyCon "ReachArgs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachPaths" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "pathsFrom") (arm (PCon "None") () (EFieldAccess (EVar "a") "paths")) (arm (PCon "Some" (PVar "f")) () (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" (PVar "m")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: cannot read ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ") — failing open to every project"))))) (DoExpr (EListLit)))) (arm (PCon "Ok" (PVar "src")) () (EBinOp "++" (EFieldAccess (EVar "a") "paths") (EApp (EVar "nonBlankPaths") (EApp (EVar "splitNl") (EVar "src")))))))))
(DTypeSig false "reachRoot" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "reachRoot" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "reachRoot" ((PCon "None")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot")))
(DTypeSig false "reachCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "reachCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseReachArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "rpath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rpath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EBlock (DoLet false false (PVar "univ") (EApp (EVar "projectUniverse") (EVar "gates"))) (DoLet false false (PVar "paths") (EApp (EVar "reachPaths") (EVar "a"))) (DoLet false false (PVar "ces") (EApp (EApp (EVar "corpusProjectEdges") (EVar "univ")) (EVar "gates"))) (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "projectDepEdges") (EApp (EVar "reachRoot") (EFieldAccess (EVar "a") "root"))) (EVar "univ")) (EVar "univ"))) (DoLet false false (PVar "sel") (EApp (EApp (EApp (EApp (EVar "reachProjects") (EVar "univ")) (EVar "deps")) (EVar "ces")) (EVar "paths"))) (DoExpr (EIf (EFieldAccess (EVar "a") "json") (EApp (EVar "putStr") (EApp (EApp (EApp (EVar "reachJson") (EApp (EApp (EVar "reachIsFailOpen") (EVar "univ")) (EVar "paths"))) (EVar "paths")) (EVar "sel"))) (EApp (EVar "putStr") (EApp (EVar "renderProjects") (EVar "sel")))))))))))))))
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
(DFunDef false "ciShardGates" ((PVar "nm") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "g") (TyCon "Gate")) "shard") (EVar "nm")))) (EVar "gs")))
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
(DData Private "CiArgs" () ((variant "CiArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "workflow" (TyApp (TyCon "Option") (TyCon "String"))) (field "check" (TyCon "Bool"))))) ())
(DTypeSig false "parseCiArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CiArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "CiArgs")))))
(DFunDef false "parseCiArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --registry needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "workflow" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --workflow needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "check" (EVar "True"))))))
(DFunDef false "parseCiArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: unexpected argument: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "ciWorkflowPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ciWorkflowPath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "ciWorkflowPath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ciWorkflowRel")))
(DTypeSig false "ciNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "ciNewText" ((PVar "root") (PVar "regPath") (PVar "regSrc") (PVar "wfSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gates")) (arm (PList) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "gen")) () (EApp (EApp (EVar "map") (EVar "joinNl")) (EApp (EApp (EVar "ciSplice") (EVar "gen")) (EApp (EVar "splitNl") (EVar "wfSrc"))))))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "")))))))))))
(DTypeSig false "ciWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "ciWrite" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "wfPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot write ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: regenerated the gates matrix in ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciDiffAt" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "ciDiffAt" ((PList) (PList) PWild) (ELit (LString "  (the two texts differ only in trailing newline)")))
(DFunDef false "ciDiffAt" ((PList) (PCons (PVar "g") PWild) (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   <end of file>\n    generated: "))) (EApp (EVar "display") (EVar "g"))) (ELit (LString ""))))
(DFunDef false "ciDiffAt" ((PCons (PVar "d") PWild) (PList) (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   "))) (EApp (EVar "display") (EVar "d"))) (ELit (LString "\n    generated: <end of file>"))))
(DFunDef false "ciDiffAt" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "g") (PVar "gs")) (PVar "n")) (EIf (EBinOp "==" (EVar "d") (EVar "g")) (EApp (EApp (EApp (EVar "ciDiffAt") (EVar "ds")) (EVar "gs")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   "))) (EApp (EVar "display") (EVar "d"))) (ELit (LString "\n    generated: "))) (EApp (EVar "display") (EVar "g"))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "ciCheckResult" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString ": the generated gates-matrix region does not\n"))) (ELit (LString "match what test/gates.toml generates.  First difference:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "wfSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'make gen-ci' and commit the result.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "ciCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseCiArgs") (EVar "argv")) (ERecordCreate "CiArgs" ((fa "registry" (EVar "None")) (fa "workflow" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "wfPath") (EApp (EApp (EVar "ciWorkflowPath") (EFieldAccess (EVar "a") "workflow")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "wfPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read ")) (EApp (EVar "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "wfSrc")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciNewText") (EVar "root")) (EVar "regPath")) (EVar "regSrc")) (EVar "wfSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "out")) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EVar "ciCheckResult") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out"))) (EApp (EApp (EApp (EVar "ciWrite") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out"))))))))))))))
(DData Private "Cand" () ((variant "Cand" (ConNamed (field "cname" (TyCon "String")) (field "crun" (TyCon "String")) (field "curRow" (TyCon "String")) (field "cms" (TyCon "Int")) (field "needsWasm" (TyCon "Bool"))))) ())
(DData Private "Row" () ((variant "Row" (ConNamed (field "rname" (TyCon "String")) (field "rwasm" (TyCon "Bool")) (field "rclosed" (TyCon "Bool")) (field "rload" (TyCon "Int")) (field "rcount" (TyCon "Int")) (field "rjobs" (TyCon "Int")) (field "rbuckets" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "Place" () ((variant "Place" (ConNamed (field "pname" (TyCon "String")) (field "pfrom" (TyCon "String")) (field "pto" (TyCon "String"))))) ())
(DTypeSig true "balOtherJob" (TyCon "String"))
(DFunDef false "balOtherJob" () (ELit (LString "other-job")))
(DTypeSig false "balTargetMilli" (TyCon "Int"))
(DFunDef false "balTargetMilli" () (ELit (LInt 1125)))
(DTypeSig false "balMarginPct" (TyCon "Int"))
(DFunDef false "balMarginPct" () (ELit (LInt 5)))
(DTypeSig false "balStabPct" (TyCon "Int"))
(DFunDef false "balStabPct" () (ELit (LInt 5)))
(DTypeSig false "balNeedsWasm" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "balNeedsWasm" ((PList)) (EVar "False"))
(DFunDef false "balNeedsWasm" ((PCons (PVar "t") (PVar "ts"))) (EIf (EBinOp "==" (EVar "t") (ELit (LString "wasm-tools"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "node"))) (EVar "t")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "balNeedsWasm") (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balUnknownRows" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUnknownRows" (PWild (PList)) (EListLit))
(DFunDef false "balUnknownRows" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EApp (EApp (EVar "balHasRow") (EFieldAccess (EVar "g") "shard")) (EVar "shs")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balHasRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "Bool"))))
(DFunDef false "balHasRow" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasRow" ((PVar "n") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EFieldAccess (EVar "s") "name") (EVar "n")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasRow") (EVar "n")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balUncosted" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUncosted" (PWild (PList)) (EListLit))
(DFunDef false "balUncosted" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (baseline key '"))) (EApp (EVar "display") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ELit (LString "')"))) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCands" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balCands" (PWild (PList)) (EListLit))
(DFunDef false "balCands" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) () (EBinOp "::" (ERecordCreate "Cand" ((fa "cname" (EFieldAccess (EVar "g") "name")) (fa "crun" (EFieldAccess (EVar "g") "run")) (fa "curRow" (EFieldAccess (EVar "g") "shard")) (fa "cms" (EVar "ms")) (fa "needsWasm" (EApp (EVar "balNeedsWasm") (EFieldAccess (EVar "g") "toolchain"))))) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRows" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Row")))))
(DFunDef false "balRows" (PWild (PList)) (EListLit))
(DFunDef false "balRows" ((PVar "runs") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EVar "balJobsFor") (EFieldAccess (EVar "s") "name")) (EVar "runs"))) (DoExpr (EBinOp "::" (ERecordCreate "Row" ((fa "rname" (EFieldAccess (EVar "s") "name")) (fa "rwasm" (EFieldAccess (EVar "s") "wasmArm")) (fa "rclosed" (EFieldAccess (EVar "s") "fullCores")) (fa "rload" (ELit (LInt 0))) (fa "rcount" (ELit (LInt 0))) (fa "rjobs" (EVar "j")) (fa "rbuckets" (EApp (EVar "balZeros") (EVar "j"))))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "ss"))))))
(DTypeSig false "balJobsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Int"))))
(DFunDef false "balJobsFor" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "parallel") (arm (PCon "Some" (PCon "False")) () (ELit (LInt 1))) (arm PWild () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "j")) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1)))))))) (arm (PCon "None") () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1))))))
(DTypeSig false "balAnyJobs" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balAnyJobs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balAnyJobs" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "j"))) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "acc")))))
(DTypeSig false "balJobsIsFallback" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Bool"))))
(DFunDef false "balJobsIsFallback" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "balZeros" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balZeros" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LInt 0)) (EApp (EVar "balZeros") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "candBefore" (TyFun (TyCon "Cand") (TyFun (TyCon "Cand") (TyCon "Bool"))))
(DFunDef false "candBefore" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EBinOp ">" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EIf (EVar "otherwise") (EBinOp "<" (EFieldAccess (EVar "a") "cname") (EFieldAccess (EVar "b") "cname")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSortCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand"))))
(DFunDef false "balSortCands" ((PList)) (EListLit))
(DFunDef false "balSortCands" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortCands" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeCands") (EApp (EVar "balSortCands") (EVar "l"))) (EApp (EVar "balSortCands") (EVar "r"))))))
(DTypeSig false "balHalve" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyTuple (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))))
(DFunDef false "balHalve" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalve" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balMergeCands" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeCands" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeCands" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "candBefore") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeCands") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeCands") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPick" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPick" ((PVar "c") (PVar "rs")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "None")))
(DTypeSig false "balPickGo" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "Option") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "balPickGo" (PWild (PList) (PCon "None")) (EVar "None"))
(DFunDef false "balPickGo" (PWild (PList) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "rname")))
(DFunDef false "balPickGo" ((PVar "c") (PCons (PVar "r") (PVar "rs")) (PVar "best")) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EFieldAccess (EVar "r") "rwasm"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EVar "otherwise") (EMatch (EVar "best") (arm (PCon "None") () (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r")))) (arm (PCon "Some" (PVar "b")) () (EIf (EBinOp "<" (EFieldAccess (EVar "r") "rload") (EFieldAccess (EVar "b") "rload")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPickStable" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPickStable" ((PVar "c") (PVar "rs")) (EMatch (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "best")) () (EIf (EApp (EApp (EApp (EVar "balStays") (EVar "c")) (EVar "best")) (EVar "rs")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "curRow")) (EApp (EVar "Some") (EVar "best"))))))
(DTypeSig false "balStays" (TyFun (TyCon "Cand") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool")))))
(DFunDef false "balStays" ((PVar "c") (PVar "best") (PVar "rs")) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "best")) (EVar "True") (EIf (EApp (EVar "not") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs"))) (EVar "False") (EIf (EVar "otherwise") (EBinOp "<=" (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (ELit (LInt 100))) (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EVar "best")) (EVar "rs")) (EBinOp "+" (ELit (LInt 100)) (EVar "balStabPct")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowTakes" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowTakes" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowTakes" ((PVar "c") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EFieldAccess (EVar "c") "curRow")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "r") "rclosed")) (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "c") "needsWasm")) (EFieldAccess (EVar "r") "rwasm"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLoad" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balRowLoad" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balRowLoad" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rload") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowLoad") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAdd" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balAdd" (PWild PWild (PList)) (EListLit))
(DFunDef false "balAdd" ((PVar "n") (PVar "ms") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "balBucketAdd") (EVar "ms")) (EFieldAccess (EVar "r") "rbuckets"))) (DoExpr (EBinOp "::" (EVariantUpdate "Row" (EVar "r") ((fa "rbuckets" (EVar "bs")) (fa "rload" (EApp (EVar "balMaxL") (EVar "bs"))) (fa "rcount" (EBinOp "+" (EFieldAccess (EVar "r") "rcount") (ELit (LInt 1)))))) (EVar "rs")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "balAdd") (EVar "n")) (EVar "ms")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBucketAdd" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balBucketAdd" ((PVar "ms") (PList)) (EBinOp "::" (EVar "ms") (EListLit)))
(DFunDef false "balBucketAdd" ((PVar "ms") (PVar "bs")) (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EApp (EVar "balMinL") (EVar "bs"))) (EVar "bs")))
(DTypeSig false "balBucketPut" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balBucketPut" (PWild PWild (PList)) (EListLit))
(DFunDef false "balBucketPut" ((PVar "ms") (PVar "m") (PCons (PVar "b") (PVar "bs"))) (EIf (EBinOp "==" (EVar "b") (EVar "m")) (EBinOp "::" (EBinOp "+" (EVar "b") (EVar "ms")) (EVar "bs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "b") (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EVar "m")) (EVar "bs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMinL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMinL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMinL" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "balMinL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "minI") (EVar "x")) (EApp (EVar "balMinL") (EVar "xs"))))
(DTypeSig false "balMaxL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMaxL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMaxL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "maxI") (EVar "x")) (EApp (EVar "balMaxL") (EVar "xs"))))
(DTypeSig false "balPlace" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row")))))))))
(DFunDef false "balPlace" (PWild (PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balPlace" ((PVar "stab") (PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EMatch (EIf (EVar "stab") (EApp (EApp (EVar "balPickStable") (EVar "c")) (EVar "rs")) (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: no row can run '")) (EApp (EVar "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "'.\n"))) (ELit (LString "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n")) (ELit (LString "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ")) (EApp (EVar "joinSpace") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (ELit (LString "\n")))))) (arm (PCon "Some" (PVar "rn")) () (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EVar "rn")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EVar "rn")))) (EVar "acc"))))))
(DTypeSig false "balWasmRowNames" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balWasmRowNames" ((PList)) (EListLit))
(DFunDef false "balWasmRowNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rwasm") (EBinOp "::" (EFieldAccess (EVar "r") "rname") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balWasmRowNames") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSeedClosed" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balSeedClosed" ((PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balSeedClosed" ((PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs"))) (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EVar "rs")) (EVar "acc")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: '")) (EApp (EVar "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "' needs the Wasm toolchain but is pinned to row '"))) (EApp (EVar "display") (EFieldAccess (EVar "c") "curRow"))) (ELit (LString "', which has wasm_arm = false")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balIsClosed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balIsClosed" (PWild (PList)) (EVar "False"))
(DFunDef false "balIsClosed" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rclosed") (EIf (EVar "otherwise") (EApp (EApp (EVar "balIsClosed") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowIsWasm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowIsWasm" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowIsWasm" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rwasm") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowIsWasm") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinErrors" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balPinErrors" (PWild (PList)) (EListLit))
(DFunDef false "balPinErrors" ((PVar "gs") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "s") "pinned")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EFieldAccess (EVar "s") "name"))) (ELit (LString "': pinned_gates is non-empty ("))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "s") "pinned")))) (ELit (LString ") on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))) (EIf (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "balRowMembers") (EFieldAccess (EVar "s") "name")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EFieldAccess (EVar "s") "name")) (EVar "gs")) (EFieldAccess (EVar "s") "pinned")) (EVar "members")) (EApp (EApp (EApp (EVar "balPinExtra") (EFieldAccess (EVar "s") "name")) (EFieldAccess (EVar "s") "pinned")) (EVar "members"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowMembers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowMembers" (PWild (PList)) (EListLit))
(DFunDef false "balRowMembers" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinMissing" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balPinMissing" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "balPinMissing" ((PVar "n") (PVar "gs") (PCons (PVar "p") (PVar "ps")) (PVar "members")) (EIf (EApp (EApp (EVar "balElemStr") (EVar "p")) (EVar "members")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "balPinPlace") (EVar "n")) (EVar "gs")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinPlace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "balPinPlace" ((PVar "n") (PVar "gs") (PVar "p")) (EMatch (EApp (EApp (EVar "balShardOfGate") (EVar "p")) (EVar "gs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' is not in the registry at all")))) (arm (PCon "Some" (PVar "other")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' is committed on row '"))) (EApp (EVar "display") (EVar "other"))) (ELit (LString "' instead"))))))
(DTypeSig false "balShardOfGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balShardOfGate" (PWild (PList)) (EVar "None"))
(DFunDef false "balShardOfGate" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EVar "Some") (EFieldAccess (EVar "g") "shard")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balShardOfGate") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinExtra" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balPinExtra" (PWild PWild (PList)) (EListLit))
(DFunDef false "balPinExtra" ((PVar "n") (PVar "pinned") (PCons (PVar "m") (PVar "ms"))) (EIf (EApp (EApp (EVar "balElemStr") (EVar "m")) (EVar "pinned")) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': '"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' is committed on this closed row but is not in its pinned_gates"))) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balElemStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balElemStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balElemStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balElemStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balOpenCands" ((PList) PWild) (EListLit))
(DFunDef false "balOpenCands" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balTarget" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balTarget" ((PVar "stab") (PVar "cs") (PVar "rows0")) (EBlock (DoLet false false (PVar "sorted") (EApp (EVar "balSortCands") (EVar "cs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "sorted")) (EVar "rows0")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "pinned") (PVar "rows1"))) () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "placed") (PVar "rows2"))) (ETuple (EBinOp "++" (EVar "pinned") (EVar "placed")) (EVar "rows2")))) (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EApp (EVar "balSortCands") (EApp (EApp (EVar "balOpenCands") (EVar "sorted")) (EVar "rows0")))) (EVar "rows1")) (EListLit))))))))
(DTypeSig false "balCurrent" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balCurrent" ((PList) (PVar "rs")) (ETuple (EListLit) (EVar "rs")))
(DFunDef false "balCurrent" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EBlock (DoLet false false (PTuple (PVar "ps") (PVar "rs2")) (EApp (EApp (EVar "balCurrent") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs")))) (DoExpr (ETuple (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "ps")) (EVar "rs2")))))
(DTypeSig false "balPole" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balPole" ((PList)) (ELit (LInt 0)))
(DFunDef false "balPole" ((PCons (PVar "r") (PVar "rs"))) (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balPole") (EVar "rs"))))
(DTypeSig false "balPoleRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balPoleRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balPoleRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balPoleRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balPoleRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balLoads" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balLoads" ((PList)) (EListLit))
(DFunDef false "balLoads" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (EFieldAccess (EVar "r") "rload") (EApp (EVar "balLoads") (EVar "rs"))))
(DTypeSig false "balSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balSortInts" ((PList)) (EListLit))
(DFunDef false "balSortInts" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortInts" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeInts") (EApp (EVar "balSortInts") (EVar "l"))) (EApp (EVar "balSortInts") (EVar "r"))))))
(DTypeSig false "balHalveI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balHalveI" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalveI" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balMergeInts" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeInts" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeInts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeInts") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeInts") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMedian" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balMedian" ((PVar "rs")) (EBlock (DoLet false false (PVar "v") (EApp (EVar "balSortInts") (EApp (EVar "balLoads") (EVar "rs")))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v")) (EBinOp "/" (EBinOp "+" (EApp (EApp (EVar "balNth") (EBinOp "-" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "v")) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v"))) (ELit (LInt 2))))))))
(DTypeSig false "balNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "balNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorGateMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int")))
(DFunDef false "balFloorGateMs" ((PVar "cs")) (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms"))
(DTypeSig false "balFloorClosedMs" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balFloorClosedMs" ((PList)) (ELit (LInt 0)))
(DFunDef false "balFloorClosedMs" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorClosedRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balFloorClosedRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balFloorClosedRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balFloorClosedRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balFloorClosedRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "r") "rclosed") (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best"))) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenWork" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balOpenWork" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOpenWork" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "c") "cms") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenSlots" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balOpenSlots" ((PList)) (ELit (LInt 0)))
(DFunDef false "balOpenSlots" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EVar "balOpenSlots") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "r") "rjobs") (EApp (EVar "balOpenSlots") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorCapMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloorCapMs" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "balOpenSlots") (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "s") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EVar "s"))))))
(DTypeSig false "balFloor" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloor" ((PVar "cs") (PVar "rs")) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorGateMs") (EVar "cs"))) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EApp (EApp (EVar "balFloorCapMs") (EVar "cs")) (EVar "rs")))))
(DTypeSig false "balFloorIsGate" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balFloorIsGate" ((PVar "cs") (PVar "rs")) (EBinOp ">=" (EApp (EVar "balFloorGateMs") (EVar "cs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))
(DTypeSig false "balFloorLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))
(DFunDef false "balFloorLine" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs")) (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by '")) (EApp (EVar "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone ("))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorGateMs") (EVar "cs"))))) (ELit (LString "), which is indivisible.\n"))) (ELit (LString "         Moving the FLOOR means that gate has to get FASTER (or be split).\n")))) (EIf (EBinOp ">=" (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by the closed row '")) (EApp (EVar "display") (EApp (EVar "balFloorClosedRow") (EVar "rs")))) (ELit (LString "' ("))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorClosedMs") (EVar "rs"))))) (ELit (LString "), whose membership the packer cannot change.\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))))) (ELit (LString " of open work over "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balOpenSlots") (EVar "rs"))))) (ELit (LString " open worker slots.\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balFactorMilli" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFactorMilli" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EBinOp "*" (EApp (EVar "balPole") (EVar "rs")) (ELit (LInt 1000))) (EVar "f"))))))
(DTypeSig false "balMaxCand" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Cand")))
(DFunDef false "balMaxCand" ((PList)) (ERecordCreate "Cand" ((fa "cname" (ELit (LString "(none)"))) (fa "crun" (ELit (LString ""))) (fa "curRow" (ELit (LString ""))) (fa "cms" (ELit (LInt 0))) (fa "needsWasm" (EVar "False")))))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PList))) (EVar "c"))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "r") (EApp (EVar "balMaxCand") (EVar "cs"))) (DoExpr (EIf (EBinOp ">=" (EFieldAccess (EVar "c") "cms") (EFieldAccess (EVar "r") "cms")) (EVar "c") (EVar "r")))))
(DTypeSig false "balSecs" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balSecs" ((PVar "ms")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "ms") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "%" (EVar "ms") (ELit (LInt 1000))) (ELit (LInt 100)))))) (ELit (LString "s"))))
(DTypeSig false "balTenth" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balTenth" ((PVar "pm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "%" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "%"))))
(DTypeSig false "balPct1" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balPct1" ((PVar "d") (PVar "base")) (EIf (EBinOp "<=" (EVar "base") (ELit (LInt 0))) (ELit (LString "n/a")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EBinOp "-" (ELit (LInt 0)) (EVar "d")) (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balMilli" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balMilli" ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "balPad3") (EBinOp "%" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString ""))))
(DTypeSig false "balPad3" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balPad3" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (EBinOp "++" (ELit (LString "00")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (EBinOp "++" (ELit (LString "0")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPadR" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadR" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadR") (EVar "w")) (EBinOp "++" (EVar "s") (ELit (LString " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPadL" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadL" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadL") (EVar "w")) (EBinOp "++" (ELit (LString " ")) (EVar "s"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDelta" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balDelta" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EVar "display") (EApp (EVar "balSecs") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EVar "display") (EApp (EVar "balSecs") (EVar "d")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowLines" ((PList) PWild) (EListLit))
(DFunDef false "balRowLines" ((PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBlock (DoLet false false (PVar "tag") (EIf (EFieldAccess (EVar "r") "rclosed") (ELit (LString "  [closed: full_cores]")) (ELit (LString "")))) (DoLet false false (PVar "jt") (EIf (EApp (EApp (EVar "balJobsIsFallback") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (ELit (LString " jobs*")) (ELit (LString " jobs ")))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 4))) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rcount"))))) (ELit (LString " gates "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "  "))) (EApp (EVar "display") (EVar "jt"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rjobs")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))) (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))))))
(DTypeSig false "balCalibLines" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balCalibLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "balCalibLines" ((PVar "cs") (PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBinOp "::" (EApp (EApp (EApp (EVar "balCalibLine") (EVar "cs")) (EVar "r")) (EVar "runs")) (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "rs")) (EVar "runs"))))
(DTypeSig false "balCalibStaleness" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "balCalibStaleness" (PWild (PCon "None") PWild PWild) (ELit (LString "")))
(DFunDef false "balCalibStaleness" ((PVar "cur") (PCon "Some" (PVar "recorded")) (PVar "curDig") (PVar "recDig")) (EIf (EBinOp "/=" (EVar "cur") (EVar "recorded")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " gates now, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded]"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balCalibSetStaleness") (EVar "cur")) (EVar "curDig")) (EVar "recDig")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibSetStaleness" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "balCalibSetStaleness" (PWild PWild (PCon "None")) (ELit (LString "")))
(DFunDef false "balCalibSetStaleness" ((PVar "n") (PVar "cur") (PCon "Some" (PVar "recorded"))) (EIf (EBinOp "==" (EVar "cur") (EVar "recorded")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: the same ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " gates by COUNT but a DIFFERENT SET (set digest "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " now, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded)]"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowDigest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balRowDigest" ((PVar "rn") (PVar "cs")) (EApp (EVar "gateSetDigest") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))))
(DTypeSig false "balRowKeys" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowKeys" (PWild (PList)) (EListLit))
(DFunDef false "balRowKeys" ((PVar "rn") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "rn")) (EBinOp "::" (EApp (EVar "baselineKey") (EFieldAccess (EVar "c") "crun")) (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyCon "Row") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balCalibLine" ((PVar "cands") (PVar "r") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (no recorded run)")))) (arm (PCon "Some" (PVar "rr")) () (EMatch (EFieldAccess (EVar "rr") "rowElapsedMs") (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (run "))) (EApp (EVar "display") (EFieldAccess (EVar "rr") "runId"))) (ELit (LString " recorded no rowElapsedMs)")))) (arm (PCon "Some" (PVar "e")) () (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "e") (EFieldAccess (EVar "r") "rload"))) (DoLet false false (PVar "pct") (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 100))) (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "%)"))) (ELit (LString "")))) (DoLet false false (PVar "stale") (EApp (EApp (EApp (EApp (EVar "balCalibStaleness") (EFieldAccess (EVar "r") "rcount")) (EFieldAccess (EVar "rr") "gates")) (EApp (EApp (EVar "balRowDigest") (EFieldAccess (EVar "r") "rname")) (EVar "cands"))) (EFieldAccess (EVar "rr") "gatesDigest"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " recorded "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "e"))))) (ELit (LString "   predicted "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "   residual "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balDelta") (EVar "d"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "pct"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "stale"))) (ELit (LString ""))))))))))
(DTypeSig false "balStabLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))))
(DFunDef false "balStabLine" ((PVar "cs") (PVar "rows0") (PVar "ps") (PVar "rows")) (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "False")) (EVar "cs")) (EVar "rows0")) (arm (PCon "Err" PWild) () (ELit (LString "  stability: the unstabilized comparison packing could not be derived\n"))) (arm (PCon "Ok" (PTuple (PVar "lps") (PVar "lrows"))) () (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  stability: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "lps"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps"))))) (ELit (LString " gates held on their committed row"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (incumbent slack ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balStabPct")))) (ELit (LString "% of a row's load)"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; pole ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rows"))))) (ELit (LString " against "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "lrows"))))) (ELit (LString " unstabilized"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "balDelta") (EBinOp "-" (EApp (EVar "balPole") (EVar "rows")) (EApp (EVar "balPole") (EVar "lrows")))))) (ELit (LString "),"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))))) (ELit (LString " against "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "lrows"))))) (ELit (LString "\n"))))))))
(DTypeSig false "balHeldCount" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int"))))
(DFunDef false "balHeldCount" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balHeldCount" ((PCons (PVar "p") (PVar "ps")) (PVar "qs")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "p") "pto") (EFieldAccess (EVar "p") "pfrom")) (EBinOp "/=" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "p") "pname")) (EVar "qs")) (EFieldAccess (EVar "p") "pto"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoved" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int")))
(DFunDef false "balMoved" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMoved" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balMoved") (EVar "ps"))) (EIf (EVar "otherwise") (EApp (EVar "balMoved") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinSamples" (TyCon "Int"))
(DFunDef false "balThinSamples" () (ELit (LInt 2)))
(DTypeSig false "balThinCount" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balThinCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "balThinCount" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "<" (EFieldAccess (EVar "c") "samples") (EVar "balThinSamples")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balThinCount") (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EVar "balThinCount") (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balThinLine" ((PVar "base")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balThinCount") (EVar "base"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "base"))))) (ELit (LString " gates are scheduled off a single sample (samples < "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balThinSamples")))) (ELit (LString ")\n"))))
(DTypeSig false "balOosBlock" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balOosBlock" ((PVar "base") (PVar "cs") (PVar "runs")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "balRunIds") (EVar "runs")) (EListLit))) (DoLet false false (PVar "nr") (EApp (EVar "listLen") (EVar "ids"))) (DoExpr (EIf (EBinOp "<" (EVar "nr") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable (")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded run(s); predicting one run from the others needs at least two)\n"))) (EBlock (DoLet false false (PVar "vs") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (DoLet false false (PVar "ne") (EApp (EVar "listLen") (EVar "vs"))) (DoExpr (EIf (EBinOp "==" (EVar "ne") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))) (ELit (LString " retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded runs\n"))) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic (leave-one-run-out over the ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " runs in runs[], across the "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ne")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates carrying a run-attributed sample from every run):\n"))) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (ELit (LInt 0))) (EVar "nr"))) (ELit (LString "\n")) (EApp (EApp (EVar "balOosSummary") (EVar "vs")) (EVar "nr")) (EApp (EVar "balOosDriftLine") (EVar "base")))))))))))
(DTypeSig false "balOosFolds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balOosFolds" ((PVar "vs") (PVar "ids") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    run ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 13))) (EApp (EApp (EVar "balNthStr") (EVar "i")) (EVar "ids"))))) (ELit (LString " predicted "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "p"))))) (ELit (LString "   actual "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "a"))))) (ELit (LString "   "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 7))) (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a"))))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balOosSummary" ((PVar "vs") (PVar "nr")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    mean |error| ")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (ELit (LInt 0))) (EVar "nr")) (ELit (LInt 0))) (EVar "nr"))))) (ELit (LString "   systematic bias "))) (EApp (EVar "display") (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a")))) (ELit (LString " (the median is the low-side robust choice — see gate_cost.packStat)\n"))))))
(DTypeSig false "balOosDriftLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balOosDriftLine" ((PVar "base")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "balStatDrift") (EVar "base"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "    WARNING: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n")))))))
(DTypeSig false "balStatDrift" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balStatDrift" ((PList)) (ELit (LInt 0)))
(DFunDef false "balStatDrift" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "packStat") (EFieldAccess (EVar "c") "ms")) (EFieldAccess (EVar "c") "medianMs")) (EApp (EVar "balStatDrift") (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balStatDrift") (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosVecs" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balOosVecs" (PWild (PList) PWild) (EListLit))
(DFunDef false "balOosVecs" ((PVar "base") (PCons (PVar "c") (PVar "cs")) (PVar "ids")) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "g")) () (EMatch (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "ids")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))))))))
(DTypeSig false "balOosVecFor" (TyFun (TyCon "GateCost") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balOosVecFor" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "balOosVecFor" ((PVar "g") (PCons (PVar "r") (PVar "rs"))) (EMatch (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EFieldAccess (EVar "g") "ms")) (EFieldAccess (EVar "g") "sampleRuns")) (EVar "None")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "v") (EVar "_s")))) (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "rs"))))))
(DTypeSig false "balSampleForRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "balSampleForRun" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" ((PVar "r") (PCons (PVar "m") (PVar "ms")) (PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EIf (EBinOp "/=" (EVar "s") (EVar "r")) (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EVar "acc") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EApp (EVar "Some") (EVar "m")))) (arm (PCon "Some" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrKnown" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrKnown" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrKnown" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "balCountAttr") (EFieldAccess (EVar "g") "sampleRuns")) (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balCountAttr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "balCountAttr" ((PList)) (ELit (LInt 0)))
(DFunDef false "balCountAttr" ((PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "balCountAttr") (EVar "ss")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balCountAttr") (EVar "ss"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrTotal" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrTotal" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrTotal" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "ms")) (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balOosPred" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosPred" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosPred" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EVar "packStat") (EApp (EApp (EVar "balDropNth") (EVar "i")) (EVar "v"))) (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosAct" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosAct" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosAct" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EApp (EVar "balNth") (EVar "i")) (EVar "v")) (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosPredAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosPredAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosActAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosActAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosAbsPm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "balOosAbsPm" ((PVar "vs") (PVar "i") (PVar "nr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "d") (EIf (EBinOp ">=" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "a") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr")) (EBinOp "+" (EVar "acc") (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "a")) (ELit (LInt 0))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDropNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balDropNth" (PWild (PList)) (EListLit))
(DFunDef false "balDropNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balDropNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRunIds" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRunIds" ((PList) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "acc")) (EListLit)))
(DFunDef false "balRunIds" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EApp (EApp (EVar "balHasStr") (EFieldAccess (EVar "r") "runId")) (EVar "acc")) (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EBinOp "::" (EFieldAccess (EVar "r") "runId") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balHasStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balHasStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasStr" ((PVar "s") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "s")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasStr") (EVar "s")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRevStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRevStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balRevStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "balNthStr" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "balNthStr" (PWild (PList)) (ELit (LString "")))
(DFunDef false "balNthStr" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNthStr") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))))
(DFunDef false "balReport" ((PVar "label") (PVar "cs") (PVar "rs") (PVar "ps") (PVar "runs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates over "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " rows\n"))) (ELit (LString "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n")) (EApp (EVar "joinNl") (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  pole ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "balPoleRow") (EVar "rs")))) (ELit (LString ")   median "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balMedian") (EVar "rs"))))) (ELit (LString "   floor "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString "   pole/floor "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))))) (ELit (LString "\n"))) (EApp (EApp (EVar "balFloorLine") (EVar "cs")) (EVar "rs")) (EBinOp "++" (EBinOp "++" (ELit (LString "  gates whose row changes: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balMoved") (EVar "ps"))))) (ELit (LString "\n"))))))
(DTypeSig false "balCurrentLegal" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balCurrentLegal" ((PList) PWild) (EVar "True"))
(DFunDef false "balCurrentLegal" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBandNote" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "balBandNote" ((PCon "True") PWild PWild) (ELit (LString " — OVERRIDDEN (illegal assignment)")))
(DFunDef false "balBandNote" (PWild (PCon "True") PWild) (ELit (LString " — TAKEN")))
(DFunDef false "balBandNote" (PWild PWild (PCon "True")) (ELit (LString " — OVERRIDDEN (the committed assignment is not the derived one)")))
(DFunDef false "balBandNote" (PWild PWild PWild) (ELit (LString " — not reached (the committed assignment already IS the derived one)")))
(DTypeSig false "balFirstMove" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "Option") (TyCon "Place"))))
(DFunDef false "balFirstMove" ((PList)) (EVar "None"))
(DFunDef false "balFirstMove" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EApp (EVar "Some") (EVar "p")) (EIf (EVar "otherwise") (EApp (EVar "balFirstMove") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoveLine" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String")))
(DFunDef false "balMoveLine" ((PVar "ps")) (EMatch (EApp (EVar "balFirstMove") (EVar "ps")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  first divergence: '")) (EApp (EVar "display") (EFieldAccess (EVar "p") "pname"))) (ELit (LString "' is committed on row '"))) (EApp (EVar "display") (EFieldAccess (EVar "p") "pfrom"))) (ELit (LString "' but derives to '"))) (EApp (EVar "display") (EFieldAccess (EVar "p") "pto"))) (ELit (LString "'.\n"))))))
(DTypeSig false "balEnforce" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balEnforce" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs")) (EVar "balTargetMilli")) (EVar "None") (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  The floor is '")) (EApp (EVar "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone, at "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms")))) (ELit (LString ", against a pole of "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString ".\n"))) (ELit (LString "  Gates are indivisible, so the pole can never go below the most expensive\n")) (ELit (LString "  gate, and the rest of this gap is what would not fit around it.  This is\n")) (ELit (LString "  a gate that has to get FASTER (or be split); repacking cannot move the\n")) (ELit (LString "  floor while it stands.\n"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  No single gate explains it — the floor is ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString " and no gate costs that\n"))) (ELit (LString "  much — so this is the packing: rows within budget exist and the heuristic\n")) (ELit (LString "  did not find them.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balShardValues" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balShardValues" ((PList) PWild) (EListLit))
(DFunDef false "balShardValues" ((PCons (PVar "g") (PVar "gs")) (PVar "ps")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EBinOp "::" (EVar "balOtherJob") (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "g") "name")) (EVar "ps")) (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPlaceOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String"))))
(DFunDef false "balPlaceOf" ((PVar "n") (PList)) (EVar "n"))
(DFunDef false "balPlaceOf" ((PVar "n") (PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "==" (EFieldAccess (EVar "p") "pname") (EVar "n")) (EFieldAccess (EVar "p") "pto") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPlaceOf") (EVar "n")) (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balSplice" ((PVar "vals") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vals")) (EVar "src")) (EVar "False")) (EListLit)))
(DTypeSig false "balSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "balSpliceGo" ((PList) (PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PList) PWild PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString " unplaced)")))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PCons (PVar "l") (PVar "ls")) (PVar "inGate") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[gate]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "True")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[shard]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "False")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "&&" (EVar "inGate") (EApp (EApp (EVar "startsWith") (ELit (LString "shard = \""))) (EVar "l"))) (EMatch (EVar "vs") (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries")))) (arm (PCons (PVar "v") (PVar "rest")) () (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "rest")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "shard = \"")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "\""))) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Private "BalArgs" () ((variant "BalArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "baseline" (TyApp (TyCon "Option") (TyCon "String"))) (field "check" (TyCon "Bool"))))) ())
(DTypeSig false "parseBalArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "BalArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BalArgs")))))
(DFunDef false "parseBalArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate balance: --registry needs a path"))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--baseline")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "baseline" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--baseline")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate balance: --baseline needs a path"))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "check" (EVar "True"))))))
(DFunDef false "parseBalArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: unexpected argument: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "balBaselinePath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balBaselinePath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "balBaselinePath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gate_cost_baseline.json"))))
(DTypeSig false "balNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "balNewText" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runsRead")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "b") (EVar "bs"))))) (ELit (LString ""))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EBinOp "::" (EVar "u") (EVar "us")))))) (ELit (LString " schedulable gate(s) have no row in the cost baseline:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "u") (EVar "us")))) (ELit (LString "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n")) (ELit (LString "  unknown one, and treating it as 0 would pile it onto the lightest row.\n")) (ELit (LString "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n")))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balPinErrors") (EVar "gates")) (EVar "shs")) (arm (PCons (PVar "e") (PVar "es")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": a closed row's membership does not match its declared `pinned_gates`:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "e") (EVar "es")))) (ELit (LString "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n")) (ELit (LString "  nothing off it, so its members are the one `shard` value no cost\n")) (ELit (LString "  measurement derives.  They are DECLARED in that [[shard]] row's\n")) (ELit (LString "  `pinned_gates` and checked against the registry in both directions,\n")) (ELit (LString "  so a hand-moved `shard` cannot be adopted as the new pin.\n")) (ELit (LString "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n")) (ELit (LString "  membership is genuinely meant to differ, and say why in its rationale\n")) (ELit (LString "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n")))))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "balCompute") (EVar "regPath")) (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runsRead")) (EVar "regSrc")))))))))))))))))
(DTypeSig false "balIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balIndent" ((PList)) (EListLit))
(DFunDef false "balIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "balIndent") (EVar "xs"))))
(DTypeSig false "balCompute" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "balCompute" ((PVar "regPath") (PVar "gates") (PVar "shs") (PVar "base") (PVar "runs") (PVar "regSrc")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoLet false false (PTuple PWild (PVar "curRows")) (EApp (EApp (EVar "balCurrent") (EApp (EVar "balSortCands") (EVar "cs"))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "ps") (PVar "rows"))) () (EBlock (DoLet false false (PVar "illegal") (EApp (EVar "not") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "curRows")))) (DoLet false false (PVar "gains") (EBinOp "<" (EBinOp "*" (EApp (EVar "balPole") (EVar "rows")) (ELit (LInt 100))) (EBinOp "*" (EApp (EVar "balPole") (EVar "curRows")) (EBinOp "-" (ELit (LInt 100)) (EVar "balMarginPct"))))) (DoLet false false (PVar "moved") (EBinOp ">" (EApp (EVar "balMoved") (EVar "ps")) (ELit (LInt 0)))) (DoLet false false (PVar "label") (EIf (EVar "illegal") (ELit (LString "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)")) (EIf (EVar "moved") (ELit (LString "rebalanced")) (ELit (LString "unchanged (the committed assignment is already the derived one)"))))) (DoLet false false (PVar "head") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "balReport") (EVar "label")) (EVar "cs")) (EVar "rows")) (EVar "ps")) (EVar "runs")) (EApp (EVar "balThinLine") (EVar "base")) (EApp (EApp (EApp (EVar "balOosBlock") (EVar "base")) (EVar "cs")) (EVar "runs")) (EApp (EApp (EApp (EApp (EVar "balStabLine") (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (EVar "ps")) (EVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "  hysteresis: a move needs a pole gain of more than ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balMarginPct")))) (ELit (LString "%"))) (EApp (EApp (EApp (EVar "balBandNote") (EVar "illegal")) (EVar "gains")) (EVar "moved")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  budget pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString ""))) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows")) (EVar "balTargetMilli")) (ELit (LString " — MET\n")) (ELit (LString " — MISSED\n"))) (EApp (EVar "balMoveLine") (EVar "ps")) (ELit (LString "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "curRows")) (EVar "runs"))) (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "balEnforce") (EVar "cs")) (EVar "rows")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "balSplice") (EApp (EApp (EVar "balShardValues") (EVar "gates")) (EVar "ps"))) (EApp (EVar "splitNl") (EVar "regSrc"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "outLines")) () (EApp (EVar "Ok") (ETuple (EVar "head") (EApp (EVar "joinNl") (EVar "outLines")))))))))))))))
(DTypeSig false "balWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "balWrite" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString " already balanced — no shard assignment changed\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "regPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: cannot write "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: rewrote the shard assignments in "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "balCheckResult" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString " already balanced\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EVar "head") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": the committed shard assignment is not the\n"))) (ELit (LString "one the balancer derives from test/gate_cost_baseline.json.  A `shard` field\n")) (ELit (LString "is DERIVED DATA (#2178): it is not hand-editable, and a hand edit that keeps\n")) (ELit (LString "ci.yml self-consistent is exactly what this check exists to catch.  First\n")) (ELit (LString "differing line:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "regSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'medaka gate balance' then 'make gen-ci', and commit both.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "balCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseBalArgs") (EVar "argv")) (ERecordCreate "BalArgs" ((fa "registry" (EVar "None")) (fa "baseline" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read cost baseline ")) (EApp (EVar "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EMatch (EApp (EApp (EApp (EVar "balNewText") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PTuple (PVar "head") (PVar "out"))) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "balCheckResult") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))) (EApp (EApp (EApp (EApp (EVar "balWrite") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))))))))))))))
(DTypeSig false "budgetOverridePrefix" (TyCon "String"))
(DFunDef false "budgetOverridePrefix" () (ELit (LString "Gate-Budget-Override: ")))
(DTypeSig false "budgetOverrideTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverrideTokens" ((PVar "msg")) (EApp (EVar "budgetTokensFromLines") (EApp (EVar "splitNl") (EVar "msg"))))
(DTypeSig false "budgetTokensFromLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetTokensFromLines" ((PList)) (EListLit))
(DFunDef false "budgetTokensFromLines" ((PCons (PVar "l") (PVar "ls"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))) (EBinOp "::" (EApp (EVar "budgetFirstWord") (EApp (EVar "stringTrim") (EApp (EApp (EVar "budgetDropPrefix") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))))) (EApp (EVar "budgetTokensFromLines") (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EVar "budgetTokensFromLines") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetDropPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetDropPrefix" ((PVar "pre") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "budgetFirstWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "budgetFirstWord" ((PVar "s")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "s")) (arm (PList) () (EVar "s")) (arm (PCons (PVar "w") PWild) () (EVar "w"))))
(DTypeSig false "budgetAcked" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "budgetAcked" ((PVar "commitMessage") (PVar "token")) (EApp (EApp (EVar "contains") (EVar "token")) (EApp (EVar "budgetOverrideTokens") (EVar "commitMessage"))))
(DTypeSig false "budgetCountUnacked" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "budgetCountUnacked" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "budgetCountUnacked" ((PVar "commitMessage") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "t")) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedNames" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedNames" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedNames" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetUncostedTokens" ((PList)) (EListLit))
(DFunDef false "budgetUncostedTokens" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))) (EApp (EVar "budgetUncostedTokens") (EVar "ns"))))
(DTypeSig false "budgetUncostedLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedLines" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedLines" ((PVar "commitMessage") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EVar "n") (EVar "ack") (ELit (LString " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this")) (ELit (LString " gate gets a sample; the `cost` field is present, the packer just has")) (ELit (LString " no price yet, so there is nothing to declare or split here.")) (ELit (LString " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "ns"))))))
(DTypeSig false "budgetTimeoutMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetTimeoutMs" ((PVar "cost")) (EBinOp "*" (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EVar "cost")) (ELit (LInt 1000))))
(DTypeSig false "budgetToleratedMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetToleratedMs" ((PVar "cost")) (EBinOp "/" (EBinOp "*" (EApp (EVar "budgetTimeoutMs") (EVar "cost")) (ELit (LInt 1000))) (EVar "balTargetMilli")))
(DTypeSig false "budgetOverClassGates" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "budgetOverClassGates" (PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassGates" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp ">" (EVar "ms") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))))) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (arm PWild () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetOverClassTokens" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverClassTokens" ((PList)) (EListLit))
(DFunDef false "budgetOverClassTokens" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ""))) (EApp (EVar "budgetOverClassTokens") (EVar "gs"))))
(DTypeSig false "budgetTimeoutRemedy" (TyCon "String"))
(DFunDef false "budgetTimeoutRemedy" () (ELit (LString "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate.")))
(DTypeSig false "budgetOverClassLines" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "budgetOverClassLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassLines" ((PVar "base") (PVar "commitMessage") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "ms") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (ELit (LInt 0))))) (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " ("))) (EApp (EVar "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString ", measured "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EVar "ms")))) (ELit (LString ", tolerance-adjusted ceiling "))) (EApp (EVar "balSecs") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))) (EBinOp "++" (EBinOp "++" (ELit (LString " of a ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s timeout)"))) (EVar "ack") (ELit (LString " — remedy: declare a higher `cost` class, split the gate into cheaper")) (ELit (LString " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the")) (ELit (LString " merge-required path. ")) (EVar "budgetTimeoutRemedy") (ELit (LString " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "gs"))))))
(DTypeSig false "budgetPoleFactor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "budgetPoleFactor" ((PVar "gates") (PVar "shs") (PVar "base") (PVar "runs")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple PWild (PVar "rows"))) () (EBlock (DoLet false false (PVar "factor") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))) (DoExpr (EIf (EBinOp "<=" (EVar "factor") (EVar "balTargetMilli")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "factor")))))))))))
(DTypeSig false "budgetPoleFloorLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetPoleFloorLines" (PWild (PCon "None")) (EListLit))
(DFunDef false "budgetPoleFloorLines" ((PVar "commitMessage") (PCon "Some" (PVar "factor"))) (EBlock (DoLet false false (PVar "tok") (ELit (LString "pole-floor"))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "factor")))) (ELit (LString " exceeds the budget "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString " (S-4)"))) (EVar "ack") (ELit (LString " — remedy: run `medaka gate balance` to see which row or gate needs to")) (ELit (LString " shrink, split the pole gate, or demote a heavy gate to")) (ELit (LString " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EListLit)))))
(DTypeSig false "budgetIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetIndent" ((PList)) (EListLit))
(DFunDef false "budgetIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "budgetIndent") (EVar "xs"))))
(DTypeSig false "budgetSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "budgetSection" (PWild (PList)) (ELit (LString "")))
(DFunDef false "budgetSection" ((PVar "title") (PVar "lines")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "lines"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinNl") (EApp (EVar "budgetIndent") (EVar "lines"))))) (ELit (LString "\n\n"))))
(DTypeSig false "budgetReport" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "budgetReport" ((PVar "base") (PVar "commitMessage") (PVar "uncosted") (PVar "overClass") (PVar "poleFactorOpt")) (EBlock (DoLet false false (PVar "aLines") (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "uncosted"))) (DoLet false false (PVar "bLines") (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "overClass"))) (DoLet false false (PVar "cLines") (EApp (EApp (EVar "budgetPoleFloorLines") (EVar "commitMessage")) (EVar "poleFactorOpt"))) (DoLet false false (PVar "aUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetUncostedTokens") (EVar "uncosted")))) (DoLet false false (PVar "bUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetOverClassTokens") (EVar "overClass")))) (DoLet false false (PVar "cCount") (EMatch (EVar "poleFactorOpt") (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" PWild) () (ELit (LInt 1))))) (DoLet false false (PVar "cUnacked") (EIf (EBinOp "==" (EVar "cCount") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (ELit (LString "pole-floor"))) (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "uncosted")) (EApp (EVar "listLen") (EVar "overClass"))) (EVar "cCount"))) (DoLet false false (PVar "unacked") (EBinOp "+" (EBinOp "+" (EVar "aUnacked") (EVar "bUnacked")) (EVar "cUnacked"))) (DoLet false false (PVar "body") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "budgetSection") (ELit (LString "no cost baseline entry (clause a)"))) (EVar "aLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "over declared class, tolerance-adjusted (clause b)"))) (EVar "bLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "projected pole/floor over budget (clause c)"))) (EVar "cLines"))))) (DoExpr (EIf (EBinOp "==" (EVar "total") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LString "medaka gate budget: OK — 0 violations.\n"))) (EIf (EBinOp "==" (EVar "unacked") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "body"))) (ELit (LString "medaka gate budget: "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s), all acknowledged by commit-message trailer — OK.\n")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "body"))) (ELit (LString "medaka gate budget: FAIL — "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "unacked")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n")))))))))
(DTypeSig false "budgetOutput" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "budgetOutput" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc") (PVar "commitMessage")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runs")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "u") (EVar "us"))))) (ELit (LString "\n"))))) (arm (PList) () (EBlock (DoLet false false (PVar "uncosted") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gates"))) (DoLet false false (PVar "overClass") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "budgetPoleFactor") (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "poleFactorOpt")) () (EApp (EApp (EApp (EApp (EApp (EVar "budgetReport") (EVar "base")) (EVar "commitMessage")) (EVar "uncosted")) (EVar "overClass")) (EVar "poleFactorOpt")))))))))))))))))
(DData Private "BudgetArgs" () ((variant "BudgetArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "baseline" (TyApp (TyCon "Option") (TyCon "String"))) (field "commitMessage" (TyCon "String"))))) ())
(DTypeSig false "budgetArgSpec" (TyCon "ArgSpec"))
(DFunDef false "budgetArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate budget"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--baseline")))) (ELit (LString "PATH"))) (ELit (LString "override the cost baseline path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--commit-message")))) (ELit (LString "TEXT"))) (ELit (LString "commit message to scan for a Gate-Budget-Override trailer")))))))
(DTypeSig false "budgetMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate budget: --registry needs a path"))) (ETuple (ELit (LString "--baseline")) (ELit (LString "medaka gate budget: --baseline needs a path"))) (ETuple (ELit (LString "--commit-message")) (ELit (LString "medaka gate budget: --commit-message needs a value")))))
(DTypeSig false "budgetCommitMessage" (TyFun (TyCon "Args") (TyCon "String")))
(DFunDef false "budgetCommitMessage" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--commit-message"))) (EVar "a")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "parseBudgetArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BudgetArgs"))))
(DFunDef false "parseBudgetArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "budgetArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "budgetArgSpec")) (EVar "budgetMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "BudgetArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "baseline" (EApp (EApp (EVar "flagValue") (ELit (LString "--baseline"))) (EVar "a"))) (fa "commitMessage" (EApp (EVar "budgetCommitMessage") (EVar "a"))))))) (arm (PCons (PVar "p") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "budgetArgSpec")) (EVar "p"))))))))
(DTypeSig false "budgetCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "budgetCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseBudgetArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: cannot read cost baseline ")) (EApp (EVar "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "budgetOutput") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (EFieldAccess (EVar "a") "commitMessage"))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "getBool" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "readDeps" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "Trailing" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "withTrailing" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "unknownFlagMessage" false) (mem "missingValueMessage" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "GateCost" false) (mem "RunRecord" false) (mem "baselineKey" false) (mem "costOf" false) (mem "costRowOf" false) (mem "gateSetDigest" false) (mem "latestRunForShard" false) (mem "packStat" false) (mem "parseCostBaseline" false) (mem "parseCostRuns" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "maxI" false) (mem "minI" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tiers" (TyApp (TyCon "List") (TyCon "String"))) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readGateEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readGateEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGateEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "tiers"))) (EVar "e"))) (ELam ((PVar "tiers")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tiers" (EVar "tiers")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DData Public "Shard" () ((variant "Shard" (ConNamed (field "name" (TyCon "String")) (field "fullCores" (TyCon "Bool")) (field "wasmArm" (TyCon "Bool")) (field "rationale" (TyCon "String")) (field "pinned" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "shardStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "shardStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardBool" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "shardBool" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Ok") (EVar "b"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required boolean field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "shardArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "shardArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readShard" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShard" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "shard"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[shard]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readShardEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readShardEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Shard")))))
(DFunDef false "readShardEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "full_cores"))) (EVar "e"))) (ELam ((PVar "fullCores")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardBool") (EVar "i")) (ELit (LString "wasm_arm"))) (EVar "e"))) (ELam ((PVar "wasmArm")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardStr") (EVar "i")) (ELit (LString "rationale"))) (EVar "e"))) (ELam ((PVar "rationale")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "shardArr") (EVar "i")) (ELit (LString "pinned_gates"))) (EVar "e"))) (ELam ((PVar "pinned")) (EApp (EVar "Ok") (ERecordCreate "Shard" ((fa "name" (EVar "name")) (fa "fullCores" (EVar "fullCores")) (fa "wasmArm" (EVar "wasmArm")) (fa "rationale" (EVar "rationale")) (fa "pinned" (EVar "pinned"))))))))))))))))
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
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "anyTierMatch") (EVar "p")) (EFieldAccess (EVar "g") "tiers")))
(DTypeSig true "anyTierMatch" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyTierMatch" (PWild (PList)) (EVar "False"))
(DFunDef false "anyTierMatch" ((PVar "p") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "t")) (EVar "True") (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EApp (EVar "tierPartOf") (EVar "t"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "anyTierMatch") (EVar "p")) (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "tierPartOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tierPartOf" ((PVar "tok")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "tok")) (arm (PList) () (EVar "tok")) (arm (PCons (PVar "t") PWild) () (EVar "t"))))
(DTypeSig true "modePartOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modePartOf" ((PVar "tok")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EApp (EVar "tierPartOf") (EVar "tok")))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (EApp (EVar "stringLength") (EVar "tok"))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))))))
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
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "baselineKey")) (EApp (EVar "JString") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "tiers")))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig false "shardJson" (TyFun (TyCon "Shard") (TyCon "Json")))
(DFunDef false "shardJson" ((PVar "sh")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "name"))) (ETuple (ELit (LString "full_cores")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "fullCores"))) (ETuple (ELit (LString "wasm_arm")) (EApp (EVar "JBool") (EFieldAccess (EVar "sh") "wasmArm"))) (ETuple (ELit (LString "rationale")) (EApp (EVar "JString") (EFieldAccess (EVar "sh") "rationale"))) (ETuple (ELit (LString "pinned_gates")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "sh") "pinned")))))))
(DTypeSig true "renderShardsJson" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShardsJson" ((PVar "shs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "shardJson")) (EVar "shs")))))
(DTypeSig false "boolWord" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolWord" ((PVar "b")) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig true "renderShards" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "String")))
(DFunDef false "renderShards" ((PList)) (ELit (LString "")))
(DFunDef false "renderShards" ((PCons (PVar "sh") (PVar "shs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "name"))) (ELit (LString ": full_cores="))) (EApp (EMethodRef "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "fullCores")))) (ELit (LString " wasm_arm="))) (EApp (EMethodRef "display") (EApp (EVar "boolWord") (EFieldAccess (EVar "sh") "wasmArm")))) (ELit (LString " rationale="))) (EApp (EMethodRef "display") (EFieldAccess (EVar "sh") "rationale"))) (ELit (LString " pinned_gates=["))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "sh") "pinned")))) (ELit (LString "]\n"))) (EApp (EVar "renderShards") (EVar "shs"))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate reach   [<changed-path>...] [--paths-from <file>] [--json]\n")) (ELit (LString "                      [--registry <path>] [--root <path>]\n")) (ELit (LString "  medaka gate ci      [--check] [--registry <path>] [--workflow <path>]\n")) (ELit (LString "  medaka gate balance [--check] [--registry <path>] [--baseline <path>]\n")) (ELit (LString "  medaka gate budget  [--registry <path>] [--baseline <path>]\n")) (ELit (LString "                      [--commit-message <text>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      a RUN of this gate: merge | nightly | ondemand, optionally\n")) (ELit (LString "                   /<mode> (the invocation delta, e.g. nightly/PERF_DEEP=1).\n")) (ELit (LString "                   A gate can have several; the glob matches a whole token or\n")) (ELit (LString "                   its tier part, so tier:nightly selects every mode.\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` only:\n")) (ELit (LString "  --check            derive the assignment in memory and report whether the\n")) (ELit (LString "                     committed one matches it; write nothing\n")) (ELit (LString "  --baseline <path>  read this cost baseline instead of\n")) (ELit (LString "                     <MEDAKA_ROOT>/test/gate_cost_baseline.json\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` CHOOSES each gate's `shard` row from the registry's own\n")) (ELit (LString "constraints plus the measured cost baseline, and rewrites the `shard = \"...\"`\n")) (ELit (LString "lines in test/gates.toml in place. A full_cores row is CLOSED: its members\n")) (ELit (LString "are declared by that [[shard]] row's `pinned_gates` and checked in both\n")) (ELit (LString "directions, so they are neither packed nor hand-assignable. A gate needing\n")) (ELit (LString "wasm-tools/node only lands on a\n")) (ELit (LString "row with wasm_arm = true. It refuses rather than pack from a missing cost,\n")) (ELit (LString "and fails when the assignment it would emit misses its pole/floor budget.\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, no two entries\n")) (ELit (LString "share a `name`, and every entry's `cost` and `tiers` are well formed.\n")) (ELit (LString "Exits nonzero on any violation. It checks the SHAPE of `tiers`, not\n")) (ELit (LString "whether it agrees with the workflows — that is\n")) (ELit (LString "test/diff_compiler_tier_drift.sh, which reads the workflow YAML.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`.\n")) (ELit (LString "\n")) (ELit (LString "  --check            ci: compare only — compute the generated text and\n")) (ELit (LString "                     compare it IN MEMORY to the file on disk, writing\n")) (ELit (LString "                     nothing. Exit 0 when they agree, 1 with the first\n")) (ELit (LString "                     differing line when they do not. This is the drift\n")) (ELit (LString "                     check; regenerating first would heal an uncommitted\n")) (ELit (LString "                     hand-edit before any diff could see it, and diffing\n")) (ELit (LString "                     the whole file would also fire on an edit OUTSIDE\n")) (ELit (LString "                     the generated region.\n")) (ELit (LString "\n")) (ELit (LString "The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")) (ELit (LString "\n")) (ELit (LString "`gate reach <changed-path>...` is the QUEUE's project scoping (#2179):\n")) (ELit (LString "which projects must run their gates for an entry touching those paths.\n")) (ELit (LString "A path under <project>/ selects that project, plus every project whose\n")) (ELit (LString "medaka.toml [dependencies] reaches it, plus the owning project of every\n")) (ELit (LString "gate whose `corpus` names a selected project. An empty list, a compiler/\n")) (ELit (LString "or stdlib/ path, and any path no project directory claims all FAIL OPEN\n")) (ELit (LString "to every project: this command never answers `nothing`.\n")) (ELit (LString "\n")) (ELit (LString "`gate budget` is #2180's governor: text-only, no build. Reds when (a) a\n")) (ELit (LString "schedulable gate has no cost baseline entry, (b) a gate's measured cost\n")) (ELit (LString "has eaten into the tolerance-adjusted timeout its declared `cost` class\n")) (ELit (LString "implies, or (c) the projected pole/floor (the same number `gate balance\n")) (ELit (LString "--check` derives) exceeds S-4's budget. Any violation may be accepted on\n")) (ELit (LString "purpose with a `Gate-Budget-Override: <token>` trailer on the commit\n")) (ELit (LString "message (there is no PR body in a merge_group run) — the failing gate\n")) (ELit (LString "prints the exact trailer to paste.\n")) (ELit (LString "\n")) (ELit (LString "  --commit-message <text>  budget: the commit message to scan for\n")) (ELit (LString "                     `Gate-Budget-Override:` trailers. Omit for none.\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "shards" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "missingValueOverride" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingValueOverride" (PWild (PList) (PVar "msg")) (EVar "msg"))
(DFunDef false "missingValueOverride" ((PVar "sp") (PCons (PTuple (PVar "flg") (PVar "custom")) (PVar "rest")) (PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "sp")) (EVar "flg"))) (EVar "custom") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "sp")) (EVar "rest")) (EVar "msg"))))
(DTypeSig false "listArgSpec" (TyCon "ArgSpec"))
(DFunDef false "listArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate list"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit machine-readable JSON"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--shards")))) (ELit (LString "print each entry's shard placement"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path")))))))
(DTypeSig false "listMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "listMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate list: --registry needs a path")))))
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs"))))
(DFunDef false "parseListArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "listArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "listArgSpec")) (EVar "listMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EApp (EVar "Ok") (ERecordCreate "ListArgs" ((fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "shards" (EApp (EApp (EVar "flag") (ELit (LString "--shards"))) (EVar "a"))) (fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "selectors" (EFieldAccess (EVar "a") "positionals"))))))))
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
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EVar "parseListArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EIf (EFieldAccess (EVar "a") "shards") (EApp (EApp (EApp (EVar "shardsOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EVar "src")) (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path"))))))))))))))
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
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate <list|run|verify|explain|reach|ci|balance|budget> [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EVar "runRunCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EVar "verifyCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) (PVar "rest"))) (EApp (EVar "explainCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "reach")) (PVar "rest"))) (EApp (EVar "reachCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "ci")) (PVar "rest"))) (EApp (EVar "ciCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "balance")) (PVar "rest"))) (EApp (EVar "balCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "budget")) (PVar "rest"))) (EApp (EVar "budgetCmdBody") (EVar "rest")))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: list, run, verify, explain, reach, ci, balance, budget)"))))))
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
(DTypeSig false "runArgSpec" (TyCon "ArgSpec"))
(DFunDef false "runArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate run"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--dry-run")))) (ELit (LString "print what would run, without running it"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the machine-readable timing report"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--no-stale-check")))) (ELit (LString "skip the stale-oracle refusal"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--report")))) (ELit (LString "PATH"))) (ELit (LString "write the timing report here"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--timeout")))) (ELit (LString "N"))) (ELit (LString "per-gate timeout, in seconds"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--jobs")))) (ELit (LString "N"))) (ELit (LString "worker count (reported only; gates run sequentially)")))))))
(DTypeSig false "runMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "runMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate run: --registry needs a path"))) (ETuple (ELit (LString "--report")) (ELit (LString "medaka gate run: --report needs a path"))) (ETuple (ELit (LString "--timeout")) (ELit (LString "medaka gate run: --timeout needs a number of seconds"))) (ETuple (ELit (LString "--jobs")) (ELit (LString "medaka gate run: --jobs needs a number")))))
(DTypeSig false "runTimeout" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "runTimeout" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--timeout"))) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (ELit (LInt 0)))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --timeout needs a whole number of seconds, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n")))))))
(DTypeSig false "runJobs" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "runJobs" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--jobs"))) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (ELit (LInt 1)))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "parseDecChecked") (EVar "v")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: --jobs needs a whole number, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n")))))))
(DTypeSig false "parseRunArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunArgs"))))
(DFunDef false "parseRunArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "runArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "runArgSpec")) (EVar "runMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EVar "runTimeout") (EVar "a")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "timeoutSecs")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "jobs")) (ERecordCreate "RunArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "selectors" (EFieldAccess (EVar "a") "positionals")) (fa "dryRun" (EApp (EApp (EVar "flag") (ELit (LString "--dry-run"))) (EVar "a"))) (fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "report" (EApp (EApp (EVar "flagValue") (ELit (LString "--report"))) (EVar "a"))) (fa "timeoutSecs" (EVar "timeoutSecs")) (fa "jobs" (EVar "jobs")) (fa "noStaleCheck" (EApp (EApp (EVar "flag") (ELit (LString "--no-stale-check"))) (EVar "a"))))))) (EApp (EVar "runJobs") (EVar "a"))))))))
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
(DFunDef false "runRunCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseRunArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate run: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectFor") (EVar "path")) (EFieldAccess (EVar "a") "selectors")) (EVar "sels")) (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "gs")) () (EApp (EApp (EVar "runSelected") (EVar "a")) (EVar "gs")))))))))))))
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
(DTypeSig false "nameCharOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nameCharOk" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EVar "True") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z")))) (EVar "True") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "_"))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "nameLeadOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nameLeadOk" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EVar "False") (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "nameCharOk") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "nameCharsOk" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nameCharsOk" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EVar "nameCharOk") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EApp (EApp (EApp (EVar "nameCharsOk") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstBadChar" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "firstBadChar" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "(none)")) (EIf (EApp (EVar "not") (EApp (EVar "nameCharOk") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))) (ELit (LString "' at position "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstBadChar") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unsafeName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unsafeName" ((PVar "kind") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "(empty): a ")) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " name is empty — it cannot be selected, quoted or generated")))) (EIf (EApp (EVar "not") (EApp (EVar "nameLeadOk") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "n")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " name must start with a letter, a digit or '_'")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "nameCharsOk") (EVar "n")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "n")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " name contains "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "firstBadChar") (EVar "n")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "n"))))) (ELit (LString " — allowed characters are letters, digits, '_', '.' and '/' (a name is emitted into ci.yml and re-read as an unquoted shell word)")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "unsafeGateNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unsafeGateNames" ((PList)) (EListLit))
(DFunDef false "unsafeGateNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "unsafeName") (ELit (LString "gate"))) (EFieldAccess (EVar "g") "name")) (EApp (EVar "unsafeGateNames") (EVar "gs"))))
(DTypeSig false "unsafeShardNames" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unsafeShardNames" ((PList)) (EListLit))
(DFunDef false "unsafeShardNames" ((PCons (PVar "s") (PVar "ss"))) (EBinOp "++" (EApp (EApp (EVar "unsafeName") (ELit (LString "shard row"))) (EFieldAccess (EVar "s") "name")) (EApp (EVar "unsafeShardNames") (EVar "ss"))))
(DTypeSig false "unsafeNameViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unsafeNameViolations" ((PVar "gates") (PVar "shs")) (EBinOp "++" (EApp (EVar "unsafeGateNames") (EVar "gates")) (EApp (EVar "unsafeShardNames") (EVar "shs"))))
(DTypeSig false "costClassOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "costClassOk" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString "cheap"))) (EBinOp "==" (EVar "c") (ELit (LString "medium")))) (EBinOp "==" (EVar "c") (ELit (LString "heavy")))))
(DTypeSig false "invalidCostViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidCostViolations" ((PList)) (EListLit))
(DFunDef false "invalidCostViolations" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "costClassOk") (EFieldAccess (EVar "g") "cost")) (EApp (EVar "invalidCostViolations") (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": cost '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString "' is not one of cheap/medium/heavy"))) (EApp (EVar "invalidCostViolations") (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tierNameOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "tierNameOk" ((PVar "t")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "t") (ELit (LString "merge"))) (EBinOp "==" (EVar "t") (ELit (LString "nightly")))) (EBinOp "==" (EVar "t") (ELit (LString "ondemand")))))
(DTypeSig false "hasModeSep" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasModeSep" ((PVar "tok")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "tok")) (EApp (EVar "stringLength") (EApp (EVar "tierPartOf") (EVar "tok")))))
(DTypeSig false "tierTokenErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tierTokenErrors" ((PVar "gname") (PVar "tok")) (EIf (EApp (EVar "not") (EApp (EVar "tierNameOk") (EApp (EVar "tierPartOf") (EVar "tok")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gname"))) (ELit (LString ": run token '"))) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' — tier '"))) (EApp (EMethodRef "display") (EApp (EVar "tierPartOf") (EVar "tok")))) (ELit (LString "' is not one of merge/nightly/ondemand")))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "tierPartOf") (EVar "tok")) (ELit (LString "ondemand"))) (EApp (EVar "hasModeSep") (EVar "tok"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gname"))) (ELit (LString ": run token '"))) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' — 'ondemand' cannot carry a mode; nothing invokes the gate, so there is no invocation for a mode to differ from")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tierTokensErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tierTokensErrors" (PWild (PList)) (EListLit))
(DFunDef false "tierTokensErrors" ((PVar "gname") (PCons (PVar "t") (PVar "ts"))) (EBinOp "++" (EApp (EApp (EVar "tierTokenErrors") (EVar "gname")) (EVar "t")) (EApp (EApp (EVar "tierTokensErrors") (EVar "gname")) (EVar "ts"))))
(DTypeSig false "hasOndemand" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasOndemand" ((PList)) (EVar "False"))
(DFunDef false "hasOndemand" ((PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "tierPartOf") (EVar "t")) (ELit (LString "ondemand"))) (EApp (EVar "hasOndemand") (EVar "ts"))))
(DTypeSig false "strictlyAscending" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "strictlyAscending" ((PList)) (EVar "True"))
(DFunDef false "strictlyAscending" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "strictlyAscending" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EBinOp "&&" (EBinOp "<" (EVar "a") (EVar "b")) (EApp (EVar "strictlyAscending") (EBinOp "::" (EVar "b") (EVar "rest")))))
(DTypeSig false "invalidTiersViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidTiersViolations" ((PList)) (EListLit))
(DFunDef false "invalidTiersViolations" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EVar "gateTiersErrors") (EVar "g")) (EApp (EVar "invalidTiersViolations") (EVar "gs"))))
(DTypeSig false "gateTiersErrors" (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gateTiersErrors" ((PVar "g")) (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "tiers")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers is empty — every gate has at least one run; a gate nothing invokes is tiers = [\"ondemand\"]")))) (EIf (EApp (EVar "not") (EApp (EVar "strictlyAscending") (EFieldAccess (EVar "g") "tiers"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EFieldAccess (EVar "g") "tiers")))) (ELit (LString " is not sorted and unique")))) (EIf (EBinOp "&&" (EApp (EVar "hasOndemand") (EFieldAccess (EVar "g") "tiers")) (EBinOp ">" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "tiers")) (ELit (LInt 1)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": tiers "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EFieldAccess (EVar "g") "tiers")))) (ELit (LString " mixes 'ondemand' with a real run — 'ondemand' means nothing invokes this gate, so it appears alone or not at all")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "tierTokensErrors") (EFieldAccess (EVar "g") "name")) (EFieldAccess (EVar "g") "tiers")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))) (ETuple (ELit (LString "unsafe entry names")) (EApp (EApp (EVar "unsafeNameViolations") (EVar "gates")) (EVar "shs"))) (ETuple (ELit (LString "invalid cost class")) (EApp (EVar "invalidCostViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid tiers")) (EApp (EVar "invalidTiersViolations") (EVar "gates"))))))))))
(DTypeSig false "renderClass" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PList))) (EBinOp "++" (EBinOp "++" (ELit (LString "OK    ")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": 0\n"))))
(DFunDef false "renderClass" ((PTuple (PVar "title") (PVar "vs"))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "joinNl") (EApp (EVar "indentedNames") (EVar "vs")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString "\n"))))))
(DTypeSig false "renderClasses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderClasses" ((PList)) (ELit (LString "")))
(DFunDef false "renderClasses" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "++" (EApp (EVar "renderClass") (EVar "c")) (EApp (EVar "renderClasses") (EVar "cs"))))
(DTypeSig false "totalViolations" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "totalViolations" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalViolations" ((PCons (PTuple PWild (PVar "vs")) (PVar "cs"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "vs")) (EApp (EVar "totalViolations") (EVar "cs"))))
(DTypeSig false "verifyOutput" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "verifyOutput" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EApp (EApp (EVar "verifyClasses") (EVar "root")) (EVar "gates")) (EVar "shs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "classes")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "totalViolations") (EVar "classes"))) (DoLet false false (PVar "body") (EApp (EVar "renderClasses") (EVar "classes"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: OK — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries, 0 violations.\n"))))) (EApp (EVar "Err") (EBinOp "++" (EVar "body") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: FAIL — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " violation(s) across "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "gates"))))) (ELit (LString " entries.\n")))))))))))
(DData Private "VerifyArgs" () ((variant "VerifyArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DTypeSig false "verifyArgSpec" (TyCon "ArgSpec"))
(DFunDef false "verifyArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate verify"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path")))))))
(DTypeSig false "verifyMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "verifyMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate verify: --registry needs a path")))))
(DTypeSig false "parseVerifyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "VerifyArgs"))))
(DFunDef false "parseVerifyArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "verifyArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "verifyArgSpec")) (EVar "verifyMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "VerifyArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))))))) (arm (PCons (PVar "p") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "verifyArgSpec")) (EVar "p"))))))))
(DTypeSig false "verifyCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseVerifyArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate verify: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "shs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EVar "emit") (EApp (EApp (EApp (EVar "verifyOutput") (EVar "root")) (EVar "gates")) (EVar "shs"))))))))))))))))
(DTypeSig true "blastRadiusPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "blastRadiusPrefixes" () (EListLit (ELit (LString "compiler/support/*")) (ELit (LString "compiler/entries/*")) (ELit (LString "stdlib/*")) (ELit (LString "runtime/*"))))
(DTypeSig false "blastHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "blastHit" ((PList) PWild) (EVar "None"))
(DFunDef false "blastHit" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EApp (EApp (EVar "globMatch") (EVar "p")) (EVar "path")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "blastHit") (EVar "ps")) (EVar "path"))))
(DTypeSig true "isProsePath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isProsePath" ((PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test/"))) (EVar "p")) (EVar "False") (EIf (EBinOp "==" (EVar "p") (ELit (LString "docs/spec/SYNTAX.md"))) (EVar "False") (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "docs/guide/"))) (EVar "p")) (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p"))) (EVar "False") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "docs/"))) (EVar "p")) (EVar "True") (EIf (EBinOp "==" (EVar "p") (ELit (LString "LICENSE"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "LICENSE."))) (EVar "p")) (EVar "True") (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".md"))) (EVar "p")) (EVar "True") (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
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
(DFunDef false "matchedFields" ((PVar "tok") (PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "fieldHit") (ELit (LString "run"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "run"))) (EApp (EApp (EVar "fieldHit") (ELit (LString "name"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "name")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "area"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "area")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "project"))) (EBinOp "==" (EVar "tok") (EFieldAccess (EVar "g") "project")))) (EApp (EApp (EVar "fieldHit") (ELit (LString "tiers"))) (EApp (EApp (EVar "anyEqStr") (EVar "tok")) (EFieldAccess (EVar "g") "tiers")))))
(DTypeSig false "anyEqStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyEqStr" (PWild (PList)) (EVar "False"))
(DFunDef false "anyEqStr" ((PVar "tok") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EVar "tok") (EVar "x")) (EApp (EApp (EVar "anyEqStr") (EVar "tok")) (EVar "xs"))))
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
(DTypeSig false "explainArgSpec" (TyCon "ArgSpec"))
(DFunDef false "explainArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate explain"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--prose")))) (ELit (LString "print only the PROSE/NONDOC verdict")))))))
(DTypeSig false "explainMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "explainMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate explain: --registry needs a path")))))
(DTypeSig false "parseExplainArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ExplainArgs"))))
(DFunDef false "parseExplainArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "explainArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "explainArgSpec")) (EVar "explainMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "ExplainArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "path" (EVar "None")) (fa "prose" (EApp (EApp (EVar "flag") (ELit (LString "--prose"))) (EVar "a"))))))) (arm (PList (PVar "p")) () (EApp (EVar "Ok") (ERecordCreate "ExplainArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "path" (EApp (EVar "Some") (EVar "p"))) (fa "prose" (EApp (EApp (EVar "flag") (ELit (LString "--prose"))) (EVar "a"))))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "medaka gate explain: expected exactly one <path> argument"))))))))
(DTypeSig false "explainCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "explainCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseExplainArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "path") (arm (PCon "None") () (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate explain <path> [--prose] [--registry <path>]"))))) (arm (PCon "Some" (PVar "tok")) () (EIf (EFieldAccess (EVar "a") "prose") (EApp (EVar "putStr") (EApp (EVar "proseVerdict") (EVar "tok"))) (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate explain: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EVar "putStr") (EApp (EApp (EVar "explainOutput") (EVar "tok")) (EVar "gates")))))))))))))))
(DTypeSig false "compilerProject" (TyCon "String"))
(DFunDef false "compilerProject" () (ELit (LString "compiler")))
(DTypeSig false "directHits" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "directHits" ((PList) PWild) (EListLit))
(DFunDef false "directHits" ((PCons (PVar "p") (PVar "ps")) (PVar "path")) (EIf (EBinOp "==" (EVar "p") (EVar "compilerProject")) (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path")) (EIf (EApp (EApp (EVar "underDir") (EVar "p")) (EVar "path")) (EBinOp "::" (EVar "p") (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "directHits") (EVar "ps")) (EVar "path")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatHits" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "concatHits" (PWild (PList)) (EListLit))
(DFunDef false "concatHits" ((PVar "univ") (PCons (PVar "path") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "directHits") (EVar "univ")) (EVar "path")) (EApp (EApp (EVar "concatHits") (EVar "univ")) (EVar "rest"))))
(DTypeSig false "allHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "allHit" (PWild (PList)) (EVar "True"))
(DFunDef false "allHit" ((PVar "univ") (PCons (PVar "path") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EApp (EApp (EVar "directHits") (EVar "univ")) (EVar "path")))) (EApp (EApp (EVar "allHit") (EVar "univ")) (EVar "rest"))))
(DTypeSig true "reachIsFailOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "reachIsFailOpen" ((PVar "univ") (PVar "paths")) (EIf (EApp (EVar "isEmptyStrs") (EVar "paths")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "not") (EApp (EApp (EVar "allHit") (EVar "univ")) (EVar "paths"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyIn" ((PList) PWild) (EVar "False"))
(DFunDef false "anyIn" ((PCons (PVar "x") (PVar "xs")) (PVar "sel")) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "x")) (EVar "sel")) (EApp (EApp (EVar "anyIn") (EVar "xs")) (EVar "sel"))))
(DTypeSig false "edgeAdds" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "edgeAdds" ((PList) PWild) (EListLit))
(DFunDef false "edgeAdds" ((PCons (PTuple (PVar "lhs") (PVar "rhs")) (PVar "rest")) (PVar "sel")) (EIf (EApp (EApp (EVar "anyIn") (EVar "rhs")) (EVar "sel")) (EBinOp "::" (EVar "lhs") (EApp (EApp (EVar "edgeAdds") (EVar "rest")) (EVar "sel"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "edgeAdds") (EVar "rest")) (EVar "sel")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "closeGo" ((PVar "fuel") (PVar "deps") (PVar "ces") (PVar "sel")) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EVar "sel") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nxt") (EApp (EVar "sortUniqS") (EBinOp "++" (EBinOp "++" (EVar "sel") (EApp (EApp (EVar "edgeAdds") (EVar "deps")) (EVar "sel"))) (EApp (EApp (EVar "edgeAdds") (EVar "ces")) (EVar "sel"))))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "nxt")) (EApp (EVar "listLen") (EVar "sel"))) (EVar "sel") (EApp (EApp (EApp (EApp (EVar "closeGo") (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "deps")) (EVar "ces")) (EVar "nxt"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "reachProjects" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reachProjects" ((PVar "univ") (PVar "deps") (PVar "ces") (PVar "paths")) (EBlock (DoLet false false (PVar "all") (EApp (EVar "sortUniqS") (EVar "univ"))) (DoExpr (EIf (EApp (EApp (EVar "reachIsFailOpen") (EDictApp "all")) (EVar "paths")) (EDictApp "all") (EApp (EApp (EApp (EApp (EVar "closeGo") (EBinOp "+" (EApp (EVar "listLen") (EDictApp "all")) (ELit (LInt 1)))) (EVar "deps")) (EVar "ces")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "concatHits") (EDictApp "all")) (EVar "paths"))))))))
(DTypeSig true "projectUniverse" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectUniverse" ((PVar "gs")) (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (ELam ((PVar "g")) (EFieldAccess (EVar "g") "project"))) (EVar "gs"))))
(DTypeSig true "corpusProjectEdges" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "corpusProjectEdges" (PWild (PList)) (EListLit))
(DFunDef false "corpusProjectEdges" ((PVar "univ") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "contains") (EVar "c")) (EVar "univ")))) (EFieldAccess (EVar "g") "corpus"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "corpusProjectEdges") (EVar "univ")) (EVar "gs"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "cs")) (EVar "rest") (EBinOp "::" (ETuple (EFieldAccess (EVar "g") "project") (EVar "cs")) (EVar "rest"))))))
(DTypeSig false "projectForRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "projectForRoot" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "projectForRoot" ((PVar "root") (PCons (PVar "q") (PVar "qs")) (PVar "dr")) (EIf (EBinOp "==" (EApp (EVar "canonicalizePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "q"))) (EApp (EVar "canonicalizePath") (EVar "dr"))) (EApp (EVar "Some") (EVar "q")) (EApp (EApp (EApp (EVar "projectForRoot") (EVar "root")) (EVar "qs")) (EVar "dr"))))
(DTypeSig false "depRootsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "depRootsOf" ((PList)) (EListLit))
(DFunDef false "depRootsOf" ((PCons (PTuple PWild (PVar "r")) (PVar "rest"))) (EBinOp "::" (EVar "r") (EApp (EVar "depRootsOf") (EVar "rest"))))
(DTypeSig false "depProjectsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "depProjectsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "depProjectsGo" ((PVar "root") (PVar "univ") (PCons (PVar "dr") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "projectForRoot") (EVar "root")) (EVar "univ")) (EVar "dr")) (arm (PCon "Some" (PVar "q")) () (EBinOp "::" (EVar "q") (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EVar "rest")))))
(DTypeSig false "depProjectsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "depProjectsOf" ((PVar "root") (PVar "univ") (PVar "p")) (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "depProjectsGo") (EVar "root")) (EVar "univ")) (EApp (EVar "depRootsOf") (EApp (EVar "readDeps") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "p")))))))
(DTypeSig false "projectDepEdges" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "projectDepEdges" (PWild PWild (PList)) (EListLit))
(DFunDef false "projectDepEdges" ((PVar "root") (PVar "univ") (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EApp (EVar "depProjectsOf") (EVar "root")) (EVar "univ")) (EVar "p"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "projectDepEdges") (EVar "root")) (EVar "univ")) (EVar "ps"))) (DoExpr (EIf (EApp (EVar "isEmptyStrs") (EVar "ds")) (EVar "rest") (EBinOp "::" (ETuple (EVar "p") (EVar "ds")) (EVar "rest"))))))
(DTypeSig false "renderProjects" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderProjects" ((PList)) (ELit (LString "")))
(DFunDef false "renderProjects" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "\n"))) (EApp (EVar "renderProjects") (EVar "ps"))))
(DTypeSig false "reachJson" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "reachJson" ((PVar "failOpen") (PVar "paths") (PVar "projects")) (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "projects")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "projects")))) (ETuple (ELit (LString "failOpen")) (EApp (EVar "JBool") (EVar "failOpen"))) (ETuple (ELit (LString "changed")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "paths"))))))) (ELit (LString "\n"))))
(DData Private "ReachArgs" () ((variant "ReachArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "root" (TyApp (TyCon "Option") (TyCon "String"))) (field "json" (TyCon "Bool")) (field "pathsFrom" (TyApp (TyCon "Option") (TyCon "String"))) (field "paths" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reachArgSpec" (TyCon "ArgSpec"))
(DFunDef false "reachArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "withTrailing") (EVar "TrailingAfterSeparator")) (EApp (EApp (EVar "spec") (ELit (LString "gate reach"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--root")))) (ELit (LString "PATH"))) (ELit (LString "override MEDAKA_ROOT"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--paths-from")))) (ELit (LString "PATH"))) (ELit (LString "read changed paths from a file"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit JSON"))))))))
(DTypeSig false "parseReachArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ReachArgs"))))
(DFunDef false "parseReachArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "reachArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EVar "reachRewriteErr") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EApp (EVar "Ok") (ERecordCreate "ReachArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "root" (EApp (EApp (EVar "flagValue") (ELit (LString "--root"))) (EVar "a"))) (fa "json" (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (fa "pathsFrom" (EApp (EApp (EVar "flagValue") (ELit (LString "--paths-from"))) (EVar "a"))) (fa "paths" (EBinOp "++" (EFieldAccess (EVar "a") "positionals") (EFieldAccess (EVar "a") "rest")))))))))
(DTypeSig false "reachRewriteErr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reachRewriteErr" ((PVar "msg")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--registry")))) (ELit (LString "medaka gate reach: --registry needs a path")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--root")))) (ELit (LString "medaka gate reach: --root needs a path")) (EIf (EBinOp "==" (EVar "msg") (EApp (EApp (EVar "missingValueMessage") (EVar "reachArgSpec")) (ELit (LString "--paths-from")))) (ELit (LString "medaka gate reach: --paths-from needs a path")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "msg")) (ELit (LInt 1)))) (EVar "msg")) (ELit (LString "; use `--` before a path starting with '-')"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nonBlankPaths" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonBlankPaths" ((PVar "xs")) (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EVar "xs")))
(DTypeSig false "reachPaths" (TyFun (TyCon "ReachArgs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachPaths" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "pathsFrom") (arm (PCon "None") () (EFieldAccess (EVar "a") "paths")) (arm (PCon "Some" (PVar "f")) () (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" (PVar "m")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: cannot read ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ") — failing open to every project"))))) (DoExpr (EListLit)))) (arm (PCon "Ok" (PVar "src")) () (EBinOp "++" (EFieldAccess (EVar "a") "paths") (EApp (EVar "nonBlankPaths") (EApp (EVar "splitNl") (EVar "src")))))))))
(DTypeSig false "reachRoot" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "reachRoot" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "reachRoot" ((PCon "None")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot")))
(DTypeSig false "reachCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "reachCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseReachArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "rpath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rpath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate reach: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "gates")) () (EBlock (DoLet false false (PVar "univ") (EApp (EVar "projectUniverse") (EVar "gates"))) (DoLet false false (PVar "paths") (EApp (EVar "reachPaths") (EVar "a"))) (DoLet false false (PVar "ces") (EApp (EApp (EVar "corpusProjectEdges") (EVar "univ")) (EVar "gates"))) (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "projectDepEdges") (EApp (EVar "reachRoot") (EFieldAccess (EVar "a") "root"))) (EVar "univ")) (EVar "univ"))) (DoLet false false (PVar "sel") (EApp (EApp (EApp (EApp (EVar "reachProjects") (EVar "univ")) (EVar "deps")) (EVar "ces")) (EVar "paths"))) (DoExpr (EIf (EFieldAccess (EVar "a") "json") (EApp (EVar "putStr") (EApp (EApp (EApp (EVar "reachJson") (EApp (EApp (EVar "reachIsFailOpen") (EVar "univ")) (EVar "paths"))) (EVar "paths")) (EVar "sel"))) (EApp (EVar "putStr") (EApp (EVar "renderProjects") (EVar "sel")))))))))))))))
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
(DFunDef false "ciShardGates" ((PVar "nm") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "g") (TyCon "Gate")) "shard") (EVar "nm")))) (EVar "gs")))
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
(DData Private "CiArgs" () ((variant "CiArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "workflow" (TyApp (TyCon "Option") (TyCon "String"))) (field "check" (TyCon "Bool"))))) ())
(DTypeSig false "parseCiArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CiArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "CiArgs")))))
(DFunDef false "parseCiArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --registry needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "workflow" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--workflow")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate ci: --workflow needs a path"))))
(DFunDef false "parseCiArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseCiArgs") (EVar "rest")) (EVariantUpdate "CiArgs" (EVar "acc") ((fa "check" (EVar "True"))))))
(DFunDef false "parseCiArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: unexpected argument: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "ciWorkflowPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ciWorkflowPath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "ciWorkflowPath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ciWorkflowRel")))
(DTypeSig false "ciNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "ciNewText" ((PVar "root") (PVar "regPath") (PVar "regSrc") (PVar "wfSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EApp (EVar "ciUnknownShards") (EVar "shs")) (EVar "gates")) (arm (PList) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciRowsLoop") (EVar "root")) (EVar "gates")) (EVar "shs")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "gen")) () (EApp (EApp (EMethodRef "map") (EVar "joinNl")) (EApp (EApp (EVar "ciSplice") (EVar "gen")) (EApp (EVar "splitNl") (EVar "wfSrc"))))))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "bad")))) (ELit (LString "")))))))))))
(DTypeSig false "ciWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "ciWrite" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "wfPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot write ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: regenerated the gates matrix in ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciDiffAt" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "ciDiffAt" ((PList) (PList) PWild) (ELit (LString "  (the two texts differ only in trailing newline)")))
(DFunDef false "ciDiffAt" ((PList) (PCons (PVar "g") PWild) (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   <end of file>\n    generated: "))) (EApp (EMethodRef "display") (EVar "g"))) (ELit (LString ""))))
(DFunDef false "ciDiffAt" ((PCons (PVar "d") PWild) (PList) (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   "))) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString "\n    generated: <end of file>"))))
(DFunDef false "ciDiffAt" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "g") (PVar "gs")) (PVar "n")) (EIf (EBinOp "==" (EVar "d") (EVar "g")) (EApp (EApp (EApp (EVar "ciDiffAt") (EVar "ds")) (EVar "gs")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ":\n    on disk:   "))) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString "\n    generated: "))) (EApp (EMethodRef "display") (EVar "g"))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "ciCheckResult" ((PVar "wfPath") (PVar "wfSrc") (PVar "out")) (EIf (EBinOp "==" (EVar "out") (EVar "wfSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString " already up to date\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString ": the generated gates-matrix region does not\n"))) (ELit (LString "match what test/gates.toml generates.  First difference:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "wfSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'make gen-ci' and commit the result.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ciCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "ciCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseCiArgs") (EVar "argv")) (ERecordCreate "CiArgs" ((fa "registry" (EVar "None")) (fa "workflow" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "wfPath") (EApp (EApp (EVar "ciWorkflowPath") (EFieldAccess (EVar "a") "workflow")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "wfPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate ci: cannot read ")) (EApp (EMethodRef "display") (EVar "wfPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "wfSrc")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ciNewText") (EVar "root")) (EVar "regPath")) (EVar "regSrc")) (EVar "wfSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "out")) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EVar "ciCheckResult") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out"))) (EApp (EApp (EApp (EVar "ciWrite") (EVar "wfPath")) (EVar "wfSrc")) (EVar "out"))))))))))))))
(DData Private "Cand" () ((variant "Cand" (ConNamed (field "cname" (TyCon "String")) (field "crun" (TyCon "String")) (field "curRow" (TyCon "String")) (field "cms" (TyCon "Int")) (field "needsWasm" (TyCon "Bool"))))) ())
(DData Private "Row" () ((variant "Row" (ConNamed (field "rname" (TyCon "String")) (field "rwasm" (TyCon "Bool")) (field "rclosed" (TyCon "Bool")) (field "rload" (TyCon "Int")) (field "rcount" (TyCon "Int")) (field "rjobs" (TyCon "Int")) (field "rbuckets" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "Place" () ((variant "Place" (ConNamed (field "pname" (TyCon "String")) (field "pfrom" (TyCon "String")) (field "pto" (TyCon "String"))))) ())
(DTypeSig true "balOtherJob" (TyCon "String"))
(DFunDef false "balOtherJob" () (ELit (LString "other-job")))
(DTypeSig false "balTargetMilli" (TyCon "Int"))
(DFunDef false "balTargetMilli" () (ELit (LInt 1125)))
(DTypeSig false "balMarginPct" (TyCon "Int"))
(DFunDef false "balMarginPct" () (ELit (LInt 5)))
(DTypeSig false "balStabPct" (TyCon "Int"))
(DFunDef false "balStabPct" () (ELit (LInt 5)))
(DTypeSig false "balNeedsWasm" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "balNeedsWasm" ((PList)) (EVar "False"))
(DFunDef false "balNeedsWasm" ((PCons (PVar "t") (PVar "ts"))) (EIf (EBinOp "==" (EVar "t") (ELit (LString "wasm-tools"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "node"))) (EVar "t")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "balNeedsWasm") (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balUnknownRows" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUnknownRows" (PWild (PList)) (EListLit))
(DFunDef false "balUnknownRows" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EApp (EApp (EVar "balHasRow") (EFieldAccess (EVar "g") "shard")) (EVar "shs")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balHasRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "Bool"))))
(DFunDef false "balHasRow" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasRow" ((PVar "n") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EFieldAccess (EVar "s") "name") (EVar "n")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasRow") (EVar "n")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balUncosted" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUncosted" (PWild (PList)) (EListLit))
(DFunDef false "balUncosted" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (baseline key '"))) (EApp (EMethodRef "display") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ELit (LString "')"))) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCands" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balCands" (PWild (PList)) (EListLit))
(DFunDef false "balCands" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) () (EBinOp "::" (ERecordCreate "Cand" ((fa "cname" (EFieldAccess (EVar "g") "name")) (fa "crun" (EFieldAccess (EVar "g") "run")) (fa "curRow" (EFieldAccess (EVar "g") "shard")) (fa "cms" (EVar "ms")) (fa "needsWasm" (EApp (EVar "balNeedsWasm") (EFieldAccess (EVar "g") "toolchain"))))) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRows" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Row")))))
(DFunDef false "balRows" (PWild (PList)) (EListLit))
(DFunDef false "balRows" ((PVar "runs") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EVar "balJobsFor") (EFieldAccess (EVar "s") "name")) (EVar "runs"))) (DoExpr (EBinOp "::" (ERecordCreate "Row" ((fa "rname" (EFieldAccess (EVar "s") "name")) (fa "rwasm" (EFieldAccess (EVar "s") "wasmArm")) (fa "rclosed" (EFieldAccess (EVar "s") "fullCores")) (fa "rload" (ELit (LInt 0))) (fa "rcount" (ELit (LInt 0))) (fa "rjobs" (EVar "j")) (fa "rbuckets" (EApp (EVar "balZeros") (EVar "j"))))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "ss"))))))
(DTypeSig false "balJobsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Int"))))
(DFunDef false "balJobsFor" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "parallel") (arm (PCon "Some" (PCon "False")) () (ELit (LInt 1))) (arm PWild () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "j")) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1)))))))) (arm (PCon "None") () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1))))))
(DTypeSig false "balAnyJobs" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balAnyJobs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balAnyJobs" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "j"))) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "acc")))))
(DTypeSig false "balJobsIsFallback" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Bool"))))
(DFunDef false "balJobsIsFallback" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "balZeros" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balZeros" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LInt 0)) (EApp (EVar "balZeros") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "candBefore" (TyFun (TyCon "Cand") (TyFun (TyCon "Cand") (TyCon "Bool"))))
(DFunDef false "candBefore" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EBinOp ">" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EIf (EVar "otherwise") (EBinOp "<" (EFieldAccess (EVar "a") "cname") (EFieldAccess (EVar "b") "cname")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSortCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand"))))
(DFunDef false "balSortCands" ((PList)) (EListLit))
(DFunDef false "balSortCands" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortCands" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeCands") (EApp (EVar "balSortCands") (EVar "l"))) (EApp (EVar "balSortCands") (EVar "r"))))))
(DTypeSig false "balHalve" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyTuple (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))))
(DFunDef false "balHalve" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalve" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balMergeCands" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeCands" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeCands" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "candBefore") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeCands") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeCands") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPick" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPick" ((PVar "c") (PVar "rs")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "None")))
(DTypeSig false "balPickGo" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "Option") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "balPickGo" (PWild (PList) (PCon "None")) (EVar "None"))
(DFunDef false "balPickGo" (PWild (PList) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "rname")))
(DFunDef false "balPickGo" ((PVar "c") (PCons (PVar "r") (PVar "rs")) (PVar "best")) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EFieldAccess (EVar "r") "rwasm"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EVar "otherwise") (EMatch (EVar "best") (arm (PCon "None") () (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r")))) (arm (PCon "Some" (PVar "b")) () (EIf (EBinOp "<" (EFieldAccess (EVar "r") "rload") (EFieldAccess (EVar "b") "rload")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPickStable" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPickStable" ((PVar "c") (PVar "rs")) (EMatch (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "best")) () (EIf (EApp (EApp (EApp (EVar "balStays") (EVar "c")) (EVar "best")) (EVar "rs")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "curRow")) (EApp (EVar "Some") (EVar "best"))))))
(DTypeSig false "balStays" (TyFun (TyCon "Cand") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool")))))
(DFunDef false "balStays" ((PVar "c") (PVar "best") (PVar "rs")) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "best")) (EVar "True") (EIf (EApp (EVar "not") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs"))) (EVar "False") (EIf (EVar "otherwise") (EBinOp "<=" (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (ELit (LInt 100))) (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EVar "best")) (EVar "rs")) (EBinOp "+" (ELit (LInt 100)) (EVar "balStabPct")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowTakes" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowTakes" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowTakes" ((PVar "c") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EFieldAccess (EVar "c") "curRow")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "r") "rclosed")) (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "c") "needsWasm")) (EFieldAccess (EVar "r") "rwasm"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLoad" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balRowLoad" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balRowLoad" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rload") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowLoad") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAdd" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balAdd" (PWild PWild (PList)) (EListLit))
(DFunDef false "balAdd" ((PVar "n") (PVar "ms") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "balBucketAdd") (EVar "ms")) (EFieldAccess (EVar "r") "rbuckets"))) (DoExpr (EBinOp "::" (EVariantUpdate "Row" (EVar "r") ((fa "rbuckets" (EVar "bs")) (fa "rload" (EApp (EVar "balMaxL") (EVar "bs"))) (fa "rcount" (EBinOp "+" (EFieldAccess (EVar "r") "rcount") (ELit (LInt 1)))))) (EVar "rs")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "balAdd") (EVar "n")) (EVar "ms")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBucketAdd" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balBucketAdd" ((PVar "ms") (PList)) (EBinOp "::" (EVar "ms") (EListLit)))
(DFunDef false "balBucketAdd" ((PVar "ms") (PVar "bs")) (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EApp (EVar "balMinL") (EVar "bs"))) (EVar "bs")))
(DTypeSig false "balBucketPut" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balBucketPut" (PWild PWild (PList)) (EListLit))
(DFunDef false "balBucketPut" ((PVar "ms") (PVar "m") (PCons (PVar "b") (PVar "bs"))) (EIf (EBinOp "==" (EVar "b") (EVar "m")) (EBinOp "::" (EBinOp "+" (EVar "b") (EVar "ms")) (EVar "bs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "b") (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EVar "m")) (EVar "bs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMinL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMinL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMinL" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "balMinL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "minI") (EVar "x")) (EApp (EVar "balMinL") (EVar "xs"))))
(DTypeSig false "balMaxL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMaxL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMaxL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "maxI") (EVar "x")) (EApp (EVar "balMaxL") (EVar "xs"))))
(DTypeSig false "balPlace" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row")))))))))
(DFunDef false "balPlace" (PWild (PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balPlace" ((PVar "stab") (PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EMatch (EIf (EVar "stab") (EApp (EApp (EVar "balPickStable") (EVar "c")) (EVar "rs")) (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: no row can run '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "'.\n"))) (ELit (LString "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n")) (ELit (LString "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ")) (EApp (EVar "joinSpace") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (ELit (LString "\n")))))) (arm (PCon "Some" (PVar "rn")) () (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EVar "rn")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EVar "rn")))) (EVar "acc"))))))
(DTypeSig false "balWasmRowNames" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balWasmRowNames" ((PList)) (EListLit))
(DFunDef false "balWasmRowNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rwasm") (EBinOp "::" (EFieldAccess (EVar "r") "rname") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balWasmRowNames") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSeedClosed" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balSeedClosed" ((PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balSeedClosed" ((PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs"))) (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EVar "rs")) (EVar "acc")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "' needs the Wasm toolchain but is pinned to row '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "curRow"))) (ELit (LString "', which has wasm_arm = false")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balIsClosed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balIsClosed" (PWild (PList)) (EVar "False"))
(DFunDef false "balIsClosed" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rclosed") (EIf (EVar "otherwise") (EApp (EApp (EVar "balIsClosed") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowIsWasm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowIsWasm" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowIsWasm" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rwasm") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowIsWasm") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinErrors" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balPinErrors" (PWild (PList)) (EListLit))
(DFunDef false "balPinErrors" ((PVar "gs") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EVar "not") (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "s") "pinned")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "s") "name"))) (ELit (LString "': pinned_gates is non-empty ("))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "s") "pinned")))) (ELit (LString ") on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))) (EIf (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "balRowMembers") (EFieldAccess (EVar "s") "name")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EFieldAccess (EVar "s") "name")) (EVar "gs")) (EFieldAccess (EVar "s") "pinned")) (EVar "members")) (EApp (EApp (EApp (EVar "balPinExtra") (EFieldAccess (EVar "s") "name")) (EFieldAccess (EVar "s") "pinned")) (EVar "members"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowMembers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowMembers" (PWild (PList)) (EListLit))
(DFunDef false "balRowMembers" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinMissing" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balPinMissing" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "balPinMissing" ((PVar "n") (PVar "gs") (PCons (PVar "p") (PVar "ps")) (PVar "members")) (EIf (EApp (EApp (EVar "balElemStr") (EVar "p")) (EVar "members")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "balPinPlace") (EVar "n")) (EVar "gs")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinPlace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "balPinPlace" ((PVar "n") (PVar "gs") (PVar "p")) (EMatch (EApp (EApp (EVar "balShardOfGate") (EVar "p")) (EVar "gs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' is not in the registry at all")))) (arm (PCon "Some" (PVar "other")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' is committed on row '"))) (EApp (EMethodRef "display") (EVar "other"))) (ELit (LString "' instead"))))))
(DTypeSig false "balShardOfGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balShardOfGate" (PWild (PList)) (EVar "None"))
(DFunDef false "balShardOfGate" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EVar "Some") (EFieldAccess (EVar "g") "shard")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balShardOfGate") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinExtra" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balPinExtra" (PWild PWild (PList)) (EListLit))
(DFunDef false "balPinExtra" ((PVar "n") (PVar "pinned") (PCons (PVar "m") (PVar "ms"))) (EIf (EApp (EApp (EVar "balElemStr") (EVar "m")) (EVar "pinned")) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': '"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' is committed on this closed row but is not in its pinned_gates"))) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balElemStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balElemStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balElemStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balElemStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balOpenCands" ((PList) PWild) (EListLit))
(DFunDef false "balOpenCands" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balTarget" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balTarget" ((PVar "stab") (PVar "cs") (PVar "rows0")) (EBlock (DoLet false false (PVar "sorted") (EApp (EVar "balSortCands") (EVar "cs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "sorted")) (EVar "rows0")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "pinned") (PVar "rows1"))) () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "placed") (PVar "rows2"))) (ETuple (EBinOp "++" (EVar "pinned") (EVar "placed")) (EVar "rows2")))) (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EApp (EVar "balSortCands") (EApp (EApp (EVar "balOpenCands") (EVar "sorted")) (EVar "rows0")))) (EVar "rows1")) (EListLit))))))))
(DTypeSig false "balCurrent" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balCurrent" ((PList) (PVar "rs")) (ETuple (EListLit) (EVar "rs")))
(DFunDef false "balCurrent" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EBlock (DoLet false false (PTuple (PVar "ps") (PVar "rs2")) (EApp (EApp (EVar "balCurrent") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs")))) (DoExpr (ETuple (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "ps")) (EVar "rs2")))))
(DTypeSig false "balPole" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balPole" ((PList)) (ELit (LInt 0)))
(DFunDef false "balPole" ((PCons (PVar "r") (PVar "rs"))) (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balPole") (EVar "rs"))))
(DTypeSig false "balPoleRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balPoleRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balPoleRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balPoleRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balPoleRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balLoads" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balLoads" ((PList)) (EListLit))
(DFunDef false "balLoads" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (EFieldAccess (EVar "r") "rload") (EApp (EVar "balLoads") (EVar "rs"))))
(DTypeSig false "balSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balSortInts" ((PList)) (EListLit))
(DFunDef false "balSortInts" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortInts" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeInts") (EApp (EVar "balSortInts") (EVar "l"))) (EApp (EVar "balSortInts") (EVar "r"))))))
(DTypeSig false "balHalveI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balHalveI" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalveI" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balMergeInts" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeInts" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeInts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeInts") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeInts") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMedian" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balMedian" ((PVar "rs")) (EBlock (DoLet false false (PVar "v") (EApp (EVar "balSortInts") (EApp (EVar "balLoads") (EVar "rs")))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v")) (EBinOp "/" (EBinOp "+" (EApp (EApp (EVar "balNth") (EBinOp "-" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "v")) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v"))) (ELit (LInt 2))))))))
(DTypeSig false "balNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "balNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorGateMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int")))
(DFunDef false "balFloorGateMs" ((PVar "cs")) (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms"))
(DTypeSig false "balFloorClosedMs" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balFloorClosedMs" ((PList)) (ELit (LInt 0)))
(DFunDef false "balFloorClosedMs" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorClosedRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balFloorClosedRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balFloorClosedRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balFloorClosedRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balFloorClosedRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "r") "rclosed") (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best"))) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenWork" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balOpenWork" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOpenWork" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "c") "cms") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenSlots" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balOpenSlots" ((PList)) (ELit (LInt 0)))
(DFunDef false "balOpenSlots" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EVar "balOpenSlots") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "r") "rjobs") (EApp (EVar "balOpenSlots") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorCapMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloorCapMs" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "balOpenSlots") (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "s") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EVar "s"))))))
(DTypeSig false "balFloor" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloor" ((PVar "cs") (PVar "rs")) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorGateMs") (EVar "cs"))) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EApp (EApp (EVar "balFloorCapMs") (EVar "cs")) (EVar "rs")))))
(DTypeSig false "balFloorIsGate" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balFloorIsGate" ((PVar "cs") (PVar "rs")) (EBinOp ">=" (EApp (EVar "balFloorGateMs") (EVar "cs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))
(DTypeSig false "balFloorLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))
(DFunDef false "balFloorLine" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs")) (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by '")) (EApp (EMethodRef "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone ("))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorGateMs") (EVar "cs"))))) (ELit (LString "), which is indivisible.\n"))) (ELit (LString "         Moving the FLOOR means that gate has to get FASTER (or be split).\n")))) (EIf (EBinOp ">=" (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by the closed row '")) (EApp (EMethodRef "display") (EApp (EVar "balFloorClosedRow") (EVar "rs")))) (ELit (LString "' ("))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorClosedMs") (EVar "rs"))))) (ELit (LString "), whose membership the packer cannot change.\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))))) (ELit (LString " of open work over "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balOpenSlots") (EVar "rs"))))) (ELit (LString " open worker slots.\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balFactorMilli" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFactorMilli" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EBinOp "*" (EApp (EVar "balPole") (EVar "rs")) (ELit (LInt 1000))) (EVar "f"))))))
(DTypeSig false "balMaxCand" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Cand")))
(DFunDef false "balMaxCand" ((PList)) (ERecordCreate "Cand" ((fa "cname" (ELit (LString "(none)"))) (fa "crun" (ELit (LString ""))) (fa "curRow" (ELit (LString ""))) (fa "cms" (ELit (LInt 0))) (fa "needsWasm" (EVar "False")))))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PList))) (EVar "c"))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "r") (EApp (EVar "balMaxCand") (EVar "cs"))) (DoExpr (EIf (EBinOp ">=" (EFieldAccess (EVar "c") "cms") (EFieldAccess (EVar "r") "cms")) (EVar "c") (EVar "r")))))
(DTypeSig false "balSecs" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balSecs" ((PVar "ms")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "ms") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "%" (EVar "ms") (ELit (LInt 1000))) (ELit (LInt 100)))))) (ELit (LString "s"))))
(DTypeSig false "balTenth" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balTenth" ((PVar "pm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "%" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "%"))))
(DTypeSig false "balPct1" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balPct1" ((PVar "d") (PVar "base")) (EIf (EBinOp "<=" (EVar "base") (ELit (LInt 0))) (ELit (LString "n/a")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EBinOp "-" (ELit (LInt 0)) (EVar "d")) (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balMilli" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balMilli" ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "balPad3") (EBinOp "%" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString ""))))
(DTypeSig false "balPad3" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balPad3" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (EBinOp "++" (ELit (LString "00")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (EBinOp "++" (ELit (LString "0")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPadR" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadR" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadR") (EVar "w")) (EBinOp "++" (EVar "s") (ELit (LString " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPadL" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadL" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadL") (EVar "w")) (EBinOp "++" (ELit (LString " ")) (EVar "s"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDelta" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balDelta" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EVar "d")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowLines" ((PList) PWild) (EListLit))
(DFunDef false "balRowLines" ((PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBlock (DoLet false false (PVar "tag") (EIf (EFieldAccess (EVar "r") "rclosed") (ELit (LString "  [closed: full_cores]")) (ELit (LString "")))) (DoLet false false (PVar "jt") (EIf (EApp (EApp (EVar "balJobsIsFallback") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (ELit (LString " jobs*")) (ELit (LString " jobs ")))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 4))) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rcount"))))) (ELit (LString " gates "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "  "))) (EApp (EMethodRef "display") (EVar "jt"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rjobs")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))) (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))))))
(DTypeSig false "balCalibLines" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balCalibLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "balCalibLines" ((PVar "cs") (PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBinOp "::" (EApp (EApp (EApp (EVar "balCalibLine") (EVar "cs")) (EVar "r")) (EVar "runs")) (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "rs")) (EVar "runs"))))
(DTypeSig false "balCalibStaleness" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "balCalibStaleness" (PWild (PCon "None") PWild PWild) (ELit (LString "")))
(DFunDef false "balCalibStaleness" ((PVar "cur") (PCon "Some" (PVar "recorded")) (PVar "curDig") (PVar "recDig")) (EIf (EBinOp "/=" (EVar "cur") (EVar "recorded")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " gates now, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded]"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balCalibSetStaleness") (EVar "cur")) (EVar "curDig")) (EVar "recDig")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibSetStaleness" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "balCalibSetStaleness" (PWild PWild (PCon "None")) (ELit (LString "")))
(DFunDef false "balCalibSetStaleness" ((PVar "n") (PVar "cur") (PCon "Some" (PVar "recorded"))) (EIf (EBinOp "==" (EVar "cur") (EVar "recorded")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: the same ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " gates by COUNT but a DIFFERENT SET (set digest "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " now, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded)]"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowDigest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balRowDigest" ((PVar "rn") (PVar "cs")) (EApp (EVar "gateSetDigest") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))))
(DTypeSig false "balRowKeys" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowKeys" (PWild (PList)) (EListLit))
(DFunDef false "balRowKeys" ((PVar "rn") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "rn")) (EBinOp "::" (EApp (EVar "baselineKey") (EFieldAccess (EVar "c") "crun")) (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyCon "Row") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balCalibLine" ((PVar "cands") (PVar "r") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (no recorded run)")))) (arm (PCon "Some" (PVar "rr")) () (EMatch (EFieldAccess (EVar "rr") "rowElapsedMs") (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (run "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "rr") "runId"))) (ELit (LString " recorded no rowElapsedMs)")))) (arm (PCon "Some" (PVar "e")) () (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "e") (EFieldAccess (EVar "r") "rload"))) (DoLet false false (PVar "pct") (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 100))) (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "%)"))) (ELit (LString "")))) (DoLet false false (PVar "stale") (EApp (EApp (EApp (EApp (EVar "balCalibStaleness") (EFieldAccess (EVar "r") "rcount")) (EFieldAccess (EVar "rr") "gates")) (EApp (EApp (EVar "balRowDigest") (EFieldAccess (EVar "r") "rname")) (EVar "cands"))) (EFieldAccess (EVar "rr") "gatesDigest"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " recorded "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "e"))))) (ELit (LString "   predicted "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "   residual "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balDelta") (EVar "d"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "pct"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "stale"))) (ELit (LString ""))))))))))
(DTypeSig false "balStabLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))))
(DFunDef false "balStabLine" ((PVar "cs") (PVar "rows0") (PVar "ps") (PVar "rows")) (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "False")) (EVar "cs")) (EVar "rows0")) (arm (PCon "Err" PWild) () (ELit (LString "  stability: the unstabilized comparison packing could not be derived\n"))) (arm (PCon "Ok" (PTuple (PVar "lps") (PVar "lrows"))) () (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  stability: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "lps"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps"))))) (ELit (LString " gates held on their committed row"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (incumbent slack ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balStabPct")))) (ELit (LString "% of a row's load)"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; pole ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rows"))))) (ELit (LString " against "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "lrows"))))) (ELit (LString " unstabilized"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "balDelta") (EBinOp "-" (EApp (EVar "balPole") (EVar "rows")) (EApp (EVar "balPole") (EVar "lrows")))))) (ELit (LString "),"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))))) (ELit (LString " against "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "lrows"))))) (ELit (LString "\n"))))))))
(DTypeSig false "balHeldCount" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int"))))
(DFunDef false "balHeldCount" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balHeldCount" ((PCons (PVar "p") (PVar "ps")) (PVar "qs")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "p") "pto") (EFieldAccess (EVar "p") "pfrom")) (EBinOp "/=" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "p") "pname")) (EVar "qs")) (EFieldAccess (EVar "p") "pto"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoved" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int")))
(DFunDef false "balMoved" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMoved" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balMoved") (EVar "ps"))) (EIf (EVar "otherwise") (EApp (EVar "balMoved") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinSamples" (TyCon "Int"))
(DFunDef false "balThinSamples" () (ELit (LInt 2)))
(DTypeSig false "balThinCount" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balThinCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "balThinCount" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "<" (EFieldAccess (EVar "c") "samples") (EVar "balThinSamples")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balThinCount") (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EVar "balThinCount") (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balThinLine" ((PVar "base")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balThinCount") (EVar "base"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "base"))))) (ELit (LString " gates are scheduled off a single sample (samples < "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balThinSamples")))) (ELit (LString ")\n"))))
(DTypeSig false "balOosBlock" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balOosBlock" ((PVar "base") (PVar "cs") (PVar "runs")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "balRunIds") (EVar "runs")) (EListLit))) (DoLet false false (PVar "nr") (EApp (EVar "listLen") (EVar "ids"))) (DoExpr (EIf (EBinOp "<" (EVar "nr") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded run(s); predicting one run from the others needs at least two)\n"))) (EBlock (DoLet false false (PVar "vs") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (DoLet false false (PVar "ne") (EApp (EVar "listLen") (EVar "vs"))) (DoExpr (EIf (EBinOp "==" (EVar "ne") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))) (ELit (LString " retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded runs\n"))) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic (leave-one-run-out over the ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " runs in runs[], across the "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ne")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates carrying a run-attributed sample from every run):\n"))) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (ELit (LInt 0))) (EVar "nr"))) (ELit (LString "\n")) (EApp (EApp (EVar "balOosSummary") (EVar "vs")) (EVar "nr")) (EApp (EVar "balOosDriftLine") (EVar "base")))))))))))
(DTypeSig false "balOosFolds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balOosFolds" ((PVar "vs") (PVar "ids") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    run ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 13))) (EApp (EApp (EVar "balNthStr") (EVar "i")) (EVar "ids"))))) (ELit (LString " predicted "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "p"))))) (ELit (LString "   actual "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "a"))))) (ELit (LString "   "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 7))) (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a"))))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balOosSummary" ((PVar "vs") (PVar "nr")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    mean |error| ")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (ELit (LInt 0))) (EVar "nr")) (ELit (LInt 0))) (EVar "nr"))))) (ELit (LString "   systematic bias "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a")))) (ELit (LString " (the median is the low-side robust choice — see gate_cost.packStat)\n"))))))
(DTypeSig false "balOosDriftLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balOosDriftLine" ((PVar "base")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "balStatDrift") (EVar "base"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "    WARNING: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n")))))))
(DTypeSig false "balStatDrift" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balStatDrift" ((PList)) (ELit (LInt 0)))
(DFunDef false "balStatDrift" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "packStat") (EFieldAccess (EVar "c") "ms")) (EFieldAccess (EVar "c") "medianMs")) (EApp (EVar "balStatDrift") (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balStatDrift") (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosVecs" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balOosVecs" (PWild (PList) PWild) (EListLit))
(DFunDef false "balOosVecs" ((PVar "base") (PCons (PVar "c") (PVar "cs")) (PVar "ids")) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "g")) () (EMatch (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "ids")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))))))))
(DTypeSig false "balOosVecFor" (TyFun (TyCon "GateCost") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balOosVecFor" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "balOosVecFor" ((PVar "g") (PCons (PVar "r") (PVar "rs"))) (EMatch (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EFieldAccess (EVar "g") "ms")) (EFieldAccess (EVar "g") "sampleRuns")) (EVar "None")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "v") (EVar "_s")))) (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "rs"))))))
(DTypeSig false "balSampleForRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "balSampleForRun" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" ((PVar "r") (PCons (PVar "m") (PVar "ms")) (PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EIf (EBinOp "/=" (EVar "s") (EVar "r")) (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EVar "acc") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EApp (EVar "Some") (EVar "m")))) (arm (PCon "Some" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrKnown" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrKnown" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrKnown" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "balCountAttr") (EFieldAccess (EVar "g") "sampleRuns")) (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balCountAttr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "balCountAttr" ((PList)) (ELit (LInt 0)))
(DFunDef false "balCountAttr" ((PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "balCountAttr") (EVar "ss")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balCountAttr") (EVar "ss"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrTotal" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrTotal" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrTotal" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "ms")) (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balOosPred" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosPred" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosPred" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EVar "packStat") (EApp (EApp (EVar "balDropNth") (EVar "i")) (EVar "v"))) (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosAct" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosAct" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosAct" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EApp (EVar "balNth") (EVar "i")) (EVar "v")) (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosPredAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosPredAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosActAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosActAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosAbsPm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "balOosAbsPm" ((PVar "vs") (PVar "i") (PVar "nr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "d") (EIf (EBinOp ">=" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "a") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr")) (EBinOp "+" (EVar "acc") (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "a")) (ELit (LInt 0))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDropNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balDropNth" (PWild (PList)) (EListLit))
(DFunDef false "balDropNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balDropNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRunIds" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRunIds" ((PList) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "acc")) (EListLit)))
(DFunDef false "balRunIds" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EApp (EApp (EVar "balHasStr") (EFieldAccess (EVar "r") "runId")) (EVar "acc")) (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EBinOp "::" (EFieldAccess (EVar "r") "runId") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balHasStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balHasStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasStr" ((PVar "s") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "s")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasStr") (EVar "s")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRevStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRevStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balRevStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "balNthStr" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "balNthStr" (PWild (PList)) (ELit (LString "")))
(DFunDef false "balNthStr" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNthStr") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))))
(DFunDef false "balReport" ((PVar "label") (PVar "cs") (PVar "rs") (PVar "ps") (PVar "runs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates over "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " rows\n"))) (ELit (LString "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n")) (EApp (EVar "joinNl") (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  pole ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "balPoleRow") (EVar "rs")))) (ELit (LString ")   median "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balMedian") (EVar "rs"))))) (ELit (LString "   floor "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString "   pole/floor "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))))) (ELit (LString "\n"))) (EApp (EApp (EVar "balFloorLine") (EVar "cs")) (EVar "rs")) (EBinOp "++" (EBinOp "++" (ELit (LString "  gates whose row changes: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balMoved") (EVar "ps"))))) (ELit (LString "\n"))))))
(DTypeSig false "balCurrentLegal" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balCurrentLegal" ((PList) PWild) (EVar "True"))
(DFunDef false "balCurrentLegal" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBandNote" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "balBandNote" ((PCon "True") PWild PWild) (ELit (LString " — OVERRIDDEN (illegal assignment)")))
(DFunDef false "balBandNote" (PWild (PCon "True") PWild) (ELit (LString " — TAKEN")))
(DFunDef false "balBandNote" (PWild PWild (PCon "True")) (ELit (LString " — OVERRIDDEN (the committed assignment is not the derived one)")))
(DFunDef false "balBandNote" (PWild PWild PWild) (ELit (LString " — not reached (the committed assignment already IS the derived one)")))
(DTypeSig false "balFirstMove" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "Option") (TyCon "Place"))))
(DFunDef false "balFirstMove" ((PList)) (EVar "None"))
(DFunDef false "balFirstMove" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EApp (EVar "Some") (EVar "p")) (EIf (EVar "otherwise") (EApp (EVar "balFirstMove") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoveLine" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String")))
(DFunDef false "balMoveLine" ((PVar "ps")) (EMatch (EApp (EVar "balFirstMove") (EVar "ps")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  first divergence: '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pname"))) (ELit (LString "' is committed on row '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pfrom"))) (ELit (LString "' but derives to '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pto"))) (ELit (LString "'.\n"))))))
(DTypeSig false "balEnforce" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balEnforce" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs")) (EVar "balTargetMilli")) (EVar "None") (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  The floor is '")) (EApp (EMethodRef "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone, at "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms")))) (ELit (LString ", against a pole of "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString ".\n"))) (ELit (LString "  Gates are indivisible, so the pole can never go below the most expensive\n")) (ELit (LString "  gate, and the rest of this gap is what would not fit around it.  This is\n")) (ELit (LString "  a gate that has to get FASTER (or be split); repacking cannot move the\n")) (ELit (LString "  floor while it stands.\n"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  No single gate explains it — the floor is ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString " and no gate costs that\n"))) (ELit (LString "  much — so this is the packing: rows within budget exist and the heuristic\n")) (ELit (LString "  did not find them.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balShardValues" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balShardValues" ((PList) PWild) (EListLit))
(DFunDef false "balShardValues" ((PCons (PVar "g") (PVar "gs")) (PVar "ps")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EBinOp "::" (EVar "balOtherJob") (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "g") "name")) (EVar "ps")) (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPlaceOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String"))))
(DFunDef false "balPlaceOf" ((PVar "n") (PList)) (EVar "n"))
(DFunDef false "balPlaceOf" ((PVar "n") (PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "==" (EFieldAccess (EVar "p") "pname") (EVar "n")) (EFieldAccess (EVar "p") "pto") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPlaceOf") (EVar "n")) (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balSplice" ((PVar "vals") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vals")) (EVar "src")) (EVar "False")) (EListLit)))
(DTypeSig false "balSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "balSpliceGo" ((PList) (PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PList) PWild PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString " unplaced)")))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PCons (PVar "l") (PVar "ls")) (PVar "inGate") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[gate]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "True")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[shard]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "False")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "&&" (EVar "inGate") (EApp (EApp (EVar "startsWith") (ELit (LString "shard = \""))) (EVar "l"))) (EMatch (EVar "vs") (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries")))) (arm (PCons (PVar "v") (PVar "rest")) () (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "rest")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "shard = \"")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "\""))) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Private "BalArgs" () ((variant "BalArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "baseline" (TyApp (TyCon "Option") (TyCon "String"))) (field "check" (TyCon "Bool"))))) ())
(DTypeSig false "parseBalArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "BalArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BalArgs")))))
(DFunDef false "parseBalArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate balance: --registry needs a path"))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--baseline")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "baseline" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--baseline")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate balance: --baseline needs a path"))))
(DFunDef false "parseBalArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseBalArgs") (EVar "rest")) (EVariantUpdate "BalArgs" (EVar "acc") ((fa "check" (EVar "True"))))))
(DFunDef false "parseBalArgs" ((PCons (PVar "a") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: unexpected argument: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))
(DTypeSig false "balBaselinePath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balBaselinePath" ((PCon "Some" (PVar "p")) PWild) (EVar "p"))
(DFunDef false "balBaselinePath" ((PCon "None") (PVar "root")) (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gate_cost_baseline.json"))))
(DTypeSig false "balNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "balNewText" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runsRead")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "b") (EVar "bs"))))) (ELit (LString ""))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EBinOp "::" (EVar "u") (EVar "us")))))) (ELit (LString " schedulable gate(s) have no row in the cost baseline:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "u") (EVar "us")))) (ELit (LString "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n")) (ELit (LString "  unknown one, and treating it as 0 would pile it onto the lightest row.\n")) (ELit (LString "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n")))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balPinErrors") (EVar "gates")) (EVar "shs")) (arm (PCons (PVar "e") (PVar "es")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": a closed row's membership does not match its declared `pinned_gates`:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "e") (EVar "es")))) (ELit (LString "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n")) (ELit (LString "  nothing off it, so its members are the one `shard` value no cost\n")) (ELit (LString "  measurement derives.  They are DECLARED in that [[shard]] row's\n")) (ELit (LString "  `pinned_gates` and checked against the registry in both directions,\n")) (ELit (LString "  so a hand-moved `shard` cannot be adopted as the new pin.\n")) (ELit (LString "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n")) (ELit (LString "  membership is genuinely meant to differ, and say why in its rationale\n")) (ELit (LString "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n")))))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "balCompute") (EVar "regPath")) (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runsRead")) (EVar "regSrc")))))))))))))))))
(DTypeSig false "balIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balIndent" ((PList)) (EListLit))
(DFunDef false "balIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "balIndent") (EVar "xs"))))
(DTypeSig false "balCompute" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "balCompute" ((PVar "regPath") (PVar "gates") (PVar "shs") (PVar "base") (PVar "runs") (PVar "regSrc")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoLet false false (PTuple PWild (PVar "curRows")) (EApp (EApp (EVar "balCurrent") (EApp (EVar "balSortCands") (EVar "cs"))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "ps") (PVar "rows"))) () (EBlock (DoLet false false (PVar "illegal") (EApp (EVar "not") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "curRows")))) (DoLet false false (PVar "gains") (EBinOp "<" (EBinOp "*" (EApp (EVar "balPole") (EVar "rows")) (ELit (LInt 100))) (EBinOp "*" (EApp (EVar "balPole") (EVar "curRows")) (EBinOp "-" (ELit (LInt 100)) (EVar "balMarginPct"))))) (DoLet false false (PVar "moved") (EBinOp ">" (EApp (EVar "balMoved") (EVar "ps")) (ELit (LInt 0)))) (DoLet false false (PVar "label") (EIf (EVar "illegal") (ELit (LString "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)")) (EIf (EVar "moved") (ELit (LString "rebalanced")) (ELit (LString "unchanged (the committed assignment is already the derived one)"))))) (DoLet false false (PVar "head") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "balReport") (EVar "label")) (EVar "cs")) (EVar "rows")) (EVar "ps")) (EVar "runs")) (EApp (EVar "balThinLine") (EVar "base")) (EApp (EApp (EApp (EVar "balOosBlock") (EVar "base")) (EVar "cs")) (EVar "runs")) (EApp (EApp (EApp (EApp (EVar "balStabLine") (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (EVar "ps")) (EVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "  hysteresis: a move needs a pole gain of more than ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balMarginPct")))) (ELit (LString "%"))) (EApp (EApp (EApp (EVar "balBandNote") (EVar "illegal")) (EVar "gains")) (EVar "moved")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  budget pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString ""))) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows")) (EVar "balTargetMilli")) (ELit (LString " — MET\n")) (ELit (LString " — MISSED\n"))) (EApp (EVar "balMoveLine") (EVar "ps")) (ELit (LString "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "curRows")) (EVar "runs"))) (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "balEnforce") (EVar "cs")) (EVar "rows")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "balSplice") (EApp (EApp (EVar "balShardValues") (EVar "gates")) (EVar "ps"))) (EApp (EVar "splitNl") (EVar "regSrc"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "outLines")) () (EApp (EVar "Ok") (ETuple (EVar "head") (EApp (EVar "joinNl") (EVar "outLines")))))))))))))))
(DTypeSig false "balWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "balWrite" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString " already balanced — no shard assignment changed\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "regPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: cannot write "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: rewrote the shard assignments in "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "balCheckResult" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString " already balanced\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EVar "head") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": the committed shard assignment is not the\n"))) (ELit (LString "one the balancer derives from test/gate_cost_baseline.json.  A `shard` field\n")) (ELit (LString "is DERIVED DATA (#2178): it is not hand-editable, and a hand edit that keeps\n")) (ELit (LString "ci.yml self-consistent is exactly what this check exists to catch.  First\n")) (ELit (LString "differing line:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "regSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'medaka gate balance' then 'make gen-ci', and commit both.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "balCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseBalArgs") (EVar "argv")) (ERecordCreate "BalArgs" ((fa "registry" (EVar "None")) (fa "baseline" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read cost baseline ")) (EApp (EMethodRef "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EMatch (EApp (EApp (EApp (EVar "balNewText") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PTuple (PVar "head") (PVar "out"))) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "balCheckResult") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))) (EApp (EApp (EApp (EApp (EVar "balWrite") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))))))))))))))
(DTypeSig false "budgetOverridePrefix" (TyCon "String"))
(DFunDef false "budgetOverridePrefix" () (ELit (LString "Gate-Budget-Override: ")))
(DTypeSig false "budgetOverrideTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverrideTokens" ((PVar "msg")) (EApp (EVar "budgetTokensFromLines") (EApp (EVar "splitNl") (EVar "msg"))))
(DTypeSig false "budgetTokensFromLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetTokensFromLines" ((PList)) (EListLit))
(DFunDef false "budgetTokensFromLines" ((PCons (PVar "l") (PVar "ls"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))) (EBinOp "::" (EApp (EVar "budgetFirstWord") (EApp (EVar "stringTrim") (EApp (EApp (EVar "budgetDropPrefix") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))))) (EApp (EVar "budgetTokensFromLines") (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EVar "budgetTokensFromLines") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetDropPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetDropPrefix" ((PVar "pre") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "budgetFirstWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "budgetFirstWord" ((PVar "s")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "s")) (arm (PList) () (EVar "s")) (arm (PCons (PVar "w") PWild) () (EVar "w"))))
(DTypeSig false "budgetAcked" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "budgetAcked" ((PVar "commitMessage") (PVar "token")) (EApp (EApp (EVar "contains") (EVar "token")) (EApp (EVar "budgetOverrideTokens") (EVar "commitMessage"))))
(DTypeSig false "budgetCountUnacked" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "budgetCountUnacked" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "budgetCountUnacked" ((PVar "commitMessage") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "t")) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedNames" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedNames" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedNames" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetUncostedTokens" ((PList)) (EListLit))
(DFunDef false "budgetUncostedTokens" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))) (EApp (EVar "budgetUncostedTokens") (EVar "ns"))))
(DTypeSig false "budgetUncostedLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedLines" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedLines" ((PVar "commitMessage") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EVar "n") (EVar "ack") (ELit (LString " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this")) (ELit (LString " gate gets a sample; the `cost` field is present, the packer just has")) (ELit (LString " no price yet, so there is nothing to declare or split here.")) (ELit (LString " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "ns"))))))
(DTypeSig false "budgetTimeoutMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetTimeoutMs" ((PVar "cost")) (EBinOp "*" (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EVar "cost")) (ELit (LInt 1000))))
(DTypeSig false "budgetToleratedMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetToleratedMs" ((PVar "cost")) (EBinOp "/" (EBinOp "*" (EApp (EVar "budgetTimeoutMs") (EVar "cost")) (ELit (LInt 1000))) (EVar "balTargetMilli")))
(DTypeSig false "budgetOverClassGates" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "budgetOverClassGates" (PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassGates" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp ">" (EVar "ms") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))))) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (arm PWild () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetOverClassTokens" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverClassTokens" ((PList)) (EListLit))
(DFunDef false "budgetOverClassTokens" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ""))) (EApp (EVar "budgetOverClassTokens") (EVar "gs"))))
(DTypeSig false "budgetTimeoutRemedy" (TyCon "String"))
(DFunDef false "budgetTimeoutRemedy" () (ELit (LString "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate.")))
(DTypeSig false "budgetOverClassLines" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "budgetOverClassLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassLines" ((PVar "base") (PVar "commitMessage") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "ms") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (ELit (LInt 0))))) (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString ", measured "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EVar "ms")))) (ELit (LString ", tolerance-adjusted ceiling "))) (EApp (EVar "balSecs") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))) (EBinOp "++" (EBinOp "++" (ELit (LString " of a ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s timeout)"))) (EVar "ack") (ELit (LString " — remedy: declare a higher `cost` class, split the gate into cheaper")) (ELit (LString " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the")) (ELit (LString " merge-required path. ")) (EVar "budgetTimeoutRemedy") (ELit (LString " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "gs"))))))
(DTypeSig false "budgetPoleFactor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "budgetPoleFactor" ((PVar "gates") (PVar "shs") (PVar "base") (PVar "runs")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple PWild (PVar "rows"))) () (EBlock (DoLet false false (PVar "factor") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))) (DoExpr (EIf (EBinOp "<=" (EVar "factor") (EVar "balTargetMilli")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "factor")))))))))))
(DTypeSig false "budgetPoleFloorLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetPoleFloorLines" (PWild (PCon "None")) (EListLit))
(DFunDef false "budgetPoleFloorLines" ((PVar "commitMessage") (PCon "Some" (PVar "factor"))) (EBlock (DoLet false false (PVar "tok") (ELit (LString "pole-floor"))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "factor")))) (ELit (LString " exceeds the budget "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString " (S-4)"))) (EVar "ack") (ELit (LString " — remedy: run `medaka gate balance` to see which row or gate needs to")) (ELit (LString " shrink, split the pole gate, or demote a heavy gate to")) (ELit (LString " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EListLit)))))
(DTypeSig false "budgetIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetIndent" ((PList)) (EListLit))
(DFunDef false "budgetIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "budgetIndent") (EVar "xs"))))
(DTypeSig false "budgetSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "budgetSection" (PWild (PList)) (ELit (LString "")))
(DFunDef false "budgetSection" ((PVar "title") (PVar "lines")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "lines"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinNl") (EApp (EVar "budgetIndent") (EVar "lines"))))) (ELit (LString "\n\n"))))
(DTypeSig false "budgetReport" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "budgetReport" ((PVar "base") (PVar "commitMessage") (PVar "uncosted") (PVar "overClass") (PVar "poleFactorOpt")) (EBlock (DoLet false false (PVar "aLines") (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "uncosted"))) (DoLet false false (PVar "bLines") (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "overClass"))) (DoLet false false (PVar "cLines") (EApp (EApp (EVar "budgetPoleFloorLines") (EVar "commitMessage")) (EVar "poleFactorOpt"))) (DoLet false false (PVar "aUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetUncostedTokens") (EVar "uncosted")))) (DoLet false false (PVar "bUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetOverClassTokens") (EVar "overClass")))) (DoLet false false (PVar "cCount") (EMatch (EVar "poleFactorOpt") (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" PWild) () (ELit (LInt 1))))) (DoLet false false (PVar "cUnacked") (EIf (EBinOp "==" (EVar "cCount") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (ELit (LString "pole-floor"))) (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "uncosted")) (EApp (EVar "listLen") (EVar "overClass"))) (EVar "cCount"))) (DoLet false false (PVar "unacked") (EBinOp "+" (EBinOp "+" (EVar "aUnacked") (EVar "bUnacked")) (EVar "cUnacked"))) (DoLet false false (PVar "body") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "budgetSection") (ELit (LString "no cost baseline entry (clause a)"))) (EVar "aLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "over declared class, tolerance-adjusted (clause b)"))) (EVar "bLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "projected pole/floor over budget (clause c)"))) (EVar "cLines"))))) (DoExpr (EIf (EBinOp "==" (EVar "total") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LString "medaka gate budget: OK — 0 violations.\n"))) (EIf (EBinOp "==" (EVar "unacked") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString "medaka gate budget: "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s), all acknowledged by commit-message trailer — OK.\n")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString "medaka gate budget: FAIL — "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "unacked")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n")))))))))
(DTypeSig false "budgetOutput" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "budgetOutput" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc") (PVar "commitMessage")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runs")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "u") (EVar "us"))))) (ELit (LString "\n"))))) (arm (PList) () (EBlock (DoLet false false (PVar "uncosted") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gates"))) (DoLet false false (PVar "overClass") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "budgetPoleFactor") (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "poleFactorOpt")) () (EApp (EApp (EApp (EApp (EApp (EVar "budgetReport") (EVar "base")) (EVar "commitMessage")) (EVar "uncosted")) (EVar "overClass")) (EVar "poleFactorOpt")))))))))))))))))
(DData Private "BudgetArgs" () ((variant "BudgetArgs" (ConNamed (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "baseline" (TyApp (TyCon "Option") (TyCon "String"))) (field "commitMessage" (TyCon "String"))))) ())
(DTypeSig false "budgetArgSpec" (TyCon "ArgSpec"))
(DFunDef false "budgetArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "gate budget"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--registry")))) (ELit (LString "PATH"))) (ELit (LString "override the gate registry path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--baseline")))) (ELit (LString "PATH"))) (ELit (LString "override the cost baseline path"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--commit-message")))) (ELit (LString "TEXT"))) (ELit (LString "commit message to scan for a Gate-Budget-Override trailer")))))))
(DTypeSig false "budgetMissingValue" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetMissingValue" () (EListLit (ETuple (ELit (LString "--registry")) (ELit (LString "medaka gate budget: --registry needs a path"))) (ETuple (ELit (LString "--baseline")) (ELit (LString "medaka gate budget: --baseline needs a path"))) (ETuple (ELit (LString "--commit-message")) (ELit (LString "medaka gate budget: --commit-message needs a value")))))
(DTypeSig false "budgetCommitMessage" (TyFun (TyCon "Args") (TyCon "String")))
(DFunDef false "budgetCommitMessage" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--commit-message"))) (EVar "a")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "parseBudgetArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BudgetArgs"))))
(DFunDef false "parseBudgetArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "budgetArgSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "missingValueOverride") (EVar "budgetArgSpec")) (EVar "budgetMissingValue")) (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EApp (EVar "Ok") (ERecordCreate "BudgetArgs" ((fa "registry" (EApp (EApp (EVar "flagValue") (ELit (LString "--registry"))) (EVar "a"))) (fa "baseline" (EApp (EApp (EVar "flagValue") (ELit (LString "--baseline"))) (EVar "a"))) (fa "commitMessage" (EApp (EVar "budgetCommitMessage") (EVar "a"))))))) (arm (PCons (PVar "p") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "unknownFlagMessage") (EVar "budgetArgSpec")) (EVar "p"))))))))
(DTypeSig false "budgetCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "budgetCmdBody" ((PVar "argv")) (EMatch (EApp (EVar "parseBudgetArgs") (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: cannot read cost baseline ")) (EApp (EMethodRef "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "budgetOutput") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (EFieldAccess (EVar "a") "commitMessage"))))))))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
