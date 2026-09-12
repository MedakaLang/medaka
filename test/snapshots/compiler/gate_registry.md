# META
source_lines=590
stages=DESUGAR,MARK
# SOURCE
{- gate_registry.mdk — the gate registry that `medaka gate` (`gate_cmd.mdk`)
   reads: the entry schema, the `migration`/`kind`/`tiers` vocabularies, a
   reader for `test/gates.toml`, the `gates` matrix rows, glob matching, the
   selector language, and the JSON/text renderers the CLI's subcommands print
   through. A private sibling of `gate_cmd.mdk` (#2176, epic #2182) — argv
   parsing and subcommand dispatch stay there; this module is what a reader
   opens to see the registry on its own.

   Selector language (design doc §3, "keep it boring"): a selector is a
   `field:pattern` token, where `field` is one of `name`/`area`/`project`/
   `tier` and `pattern` is a glob (`*`, `?`). A bare token with no `field:`
   prefix is sugar for `name:<token>`. Several selectors on one command line
   are a CONJUNCTION — a gate must match all of them.

   A selector that matches ZERO gates is a HARD ERROR, never a green empty
   list. That mirrors `test/run_gates.sh:181` ("no gates match: …", exit 1)
   deliberately: a mistyped pattern that silently selects nothing is how a
   shard certifies coverage of a gate that never ran. -}

import toml.{Toml, parse, getString, getArray, getBool, tableCount, tableEntry}
import json.{Json, JString, JBool, jArray, jObject, stringify}
import tools.gate_cost.{baselineKey}
import support.util.{splitOnChar}
import regex.{mustCompile, isFullMatch, escape}

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
-- ── `migration` (#2591) ─────────────────────────────────────────────────────
--
-- `migration` is this gate's DESTINATION under the testing-architecture epic
-- (#2600): where the check ends up, or the named prerequisite that has to be
-- discharged before a destination can be picked.  It is a required string on
-- every entry, one of eight values (checked by `migrationClassOk` in
-- `compiler/tools/gate_cmd.mdk`):
--
--   native-wrap            a native gate module invokes the existing script and
--                          asserts on it; the script's LOGIC survives verbatim.
--                          The release valve — it needs nothing built first.
--   native-rewrite         the check becomes Medaka code; the script's probes
--                          and static text become library calls, so its logic
--                          does NOT survive as an invocation.
--   shell:trust-anchor     stays shell forever.  It checks the machinery a
--                          native gate would run INSIDE, so a native rewrite
--                          would assert on itself.
--   shell:instrumentation  stays shell.  It drives valgrind/cachegrind/wall
--                          clock and does statistics over the result; a wrapper
--                          adds a layer and proves nothing new.
--   shell:external-harness stays shell.  Its SUBJECT is a shell/python/browser
--                          harness or live `gh` state, not Medaka code.
--   split-first            one script holding two things — a check and a shared
--                          helper, or several unrelated sections.  The
--                          editorial split is the prerequisite, not the port.
--   inverted-polarity      a pinning gate whose RED is the healthy state
--                          (`test/diff_compiler_must_fail.sh` and kin).  Needs a
--                          per-pin drain field before any destination is safe.
--   done                   already migrated.  Nothing carries it yet.
--
-- The three `shell:*` values are claims about a SCRIPT, so they are checked
-- against that script rather than taken on the registry's word: the `run`
-- target must carry a `shell-because: <class> …` header line naming the same
-- class (verify check 11).  Without that pairing, "stays shell" is a value one
-- side asserts and nothing reads — and a script that later stops being a trust
-- anchor would keep its exemption silently.
--
-- ── `kind` (#2591, epic #2600) ──────────────────────────────────────────────
--
-- HOW the `run` target is executed, and therefore what shape `run` has:
--
--   exec    a script.  `run` is its repo-relative path; the interpreter comes
--           from its shebang, not from this field.
--   native  a Medaka test module.  `run` is a repo-relative `*_test.mdk` path,
--           executed by `medaka test --native --json`.
--
-- The suffix is the pairing that keeps the two halves from disagreeing —
-- `test/diff_compiler_ci_shard_coverage.sh` reds an entry whose `kind` and
-- `run` suffix do not match, the same way check 11 pairs `shell:*` with a
-- `shell-because:` header.  Every pattern-to-gate resolver in the tree
-- (`test/run_gates.sh`, `test/preflight.sh`, `test/build_oracles.sh --for`,
-- `.github/workflows/ci.yml`'s `plan` step) resolves a `native` entry by
-- registry NAME, since there is no `.sh` for its glob to find.
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
  migration : String,
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
  migration <- reqStr i "migration" e
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
    migration = migration,
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
--
-- Translated to a `regex` pattern rather than hand-matched: `*` becomes `.*`,
-- `?` becomes `.`, and every other character is escaped and matched via
-- `isFullMatch`. Where the old backtracking matcher ("try consuming 0, 1,
-- 2, … characters") could take exponential time on an adversarial pattern
-- like `*a*a*a*a*b`, the Pike-VM `regex` engine matches the same patterns in
-- linear time — the accept/reject answer is unchanged, only the time bound.

-- Every character of `pat` translated to its regex-source equivalent.
globToRegexSrc : Array Char -> Int -> List String
globToRegexSrc pat i
  | i >= arrayLength pat = []
  | arrayGetUnsafe i pat == '*' = ".*" :: globToRegexSrc pat (i + 1)
  | arrayGetUnsafe i pat == '?' = "." :: globToRegexSrc pat (i + 1)
  | otherwise =
    escape (charToStr (arrayGetUnsafe i pat)) :: globToRegexSrc pat (i + 1)

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
   True

   Several `*` in one pattern:

   > globMatch "a*b*c" "aXXbYYc"
   True
   > globMatch "a*b*c" "aXXbYY"
   False

   The classic exponential-blowup shape for a backtracking glob matcher
   (`*a*a*a*a*b` against a long run of `a`s with no trailing `b`) still
   rejects, and returns fast rather than eventually:

   > globMatch "*a*a*a*a*a*a*a*a*a*a*b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
   False -}
export
globMatch : String -> String -> Bool
globMatch pat s =
  isFullMatch
    (mustCompile (stringConcat (globToRegexSrc (stringToChars pat) 0)))
    s

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

-- Space-join, no trailing separator.
export
joinSpace : List String -> String
joinSpace [] = ""
joinSpace (x :: []) = x
joinSpace (x :: xs) = "\{x} \{joinSpace xs}"

export
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
  ("migration", JString g.migration),
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
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "baselineKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("regex") ((mem "mustCompile" false) (mem "isFullMatch" false) (mem "escape" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tiers" (TyApp (TyCon "List") (TyCon "String"))) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "migration" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readGateEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readGateEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGateEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "tiers"))) (EVar "e"))) (ELam ((PVar "tiers")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "migration"))) (EVar "e"))) (ELam ((PVar "migration")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tiers" (EVar "tiers")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "migration" (EVar "migration")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))))
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
(DTypeSig false "globToRegexSrc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "globToRegexSrc" ((PVar "pat") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "pat"))) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")) (ELit (LChar "*"))) (EBinOp "::" (ELit (LString ".*")) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")) (ELit (LChar "?"))) (EBinOp "::" (ELit (LString ".")) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escape") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")))) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EApp (EApp (EVar "isFullMatch") (EApp (EVar "mustCompile") (EApp (EVar "stringConcat") (EApp (EApp (EVar "globToRegexSrc") (EApp (EVar "stringToChars") (EVar "pat"))) (ELit (LInt 0)))))) (EVar "s")))
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
(DTypeSig true "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "baselineKey")) (EApp (EVar "JString") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "tiers")))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "migration")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "migration"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
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
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "getBool" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "baselineKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("regex") ((mem "mustCompile" false) (mem "isFullMatch" false) (mem "escape" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "shard" (TyCon "String")) (field "project" (TyCon "String")) (field "tiers" (TyApp (TyCon "List") (TyCon "String"))) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "migration" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": no such entry"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "readGateEntry") (EVar "i")) (EVar "e")))))
(DTypeSig false "readGateEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGateEntry" ((PVar "i") (PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "shard"))) (EVar "e"))) (ELam ((PVar "shard")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "tiers"))) (EVar "e"))) (ELam ((PVar "tiers")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "migration"))) (EVar "e"))) (ELam ((PVar "migration")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "shard" (EVar "shard")) (fa "project" (EVar "project")) (fa "tiers" (EVar "tiers")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "migration" (EVar "migration")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))))
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
(DTypeSig false "globToRegexSrc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "globToRegexSrc" ((PVar "pat") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "pat"))) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")) (ELit (LChar "*"))) (EBinOp "::" (ELit (LString ".*")) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")) (ELit (LChar "?"))) (EBinOp "::" (ELit (LString ".")) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escape") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pat")))) (EApp (EApp (EVar "globToRegexSrc") (EVar "pat")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EApp (EApp (EVar "isFullMatch") (EApp (EVar "mustCompile") (EApp (EVar "stringConcat") (EApp (EApp (EVar "globToRegexSrc") (EApp (EVar "stringToChars") (EVar "pat"))) (ELit (LInt 0)))))) (EVar "s")))
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
(DTypeSig true "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "baselineKey")) (EApp (EVar "JString") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "shard")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "shard"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "tiers")))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "migration")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "migration"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
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
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
