# META
source_lines=2824
stages=DESUGAR,MARK
# SOURCE
{- gate_cmd.mdk — `medaka gate`, the gate-registry driver (#2176, epic #2182).

   Four commands: `medaka gate list [<selector>...] [--json]` (the read path —
   the registry schema `test/gates.toml`, a reader for it, and the selector
   language live in the sibling `gate_registry.mdk`), `medaka gate run
   [<selector>...]`, which EXECUTES the selected gates, `medaka gate verify`
   (the drift gate: TEXT-ONLY, no build — every gate candidate
   enrolled-or-ledgered, every entry's `run`/`oracles`/`corpus` targets exist,
   every entry reachable by a selector, every `name` unique and inside a
   charset safe to interpolate into YAML and into a shell word) and `medaka gate
   explain <path>` (the reverse lookup: which entries does a CHANGED PATH
   select, via which `sources` glob or `corpus` directory, and what the
   registry-level fail-open policy says about it —
   `docs/ops/GATE-REGISTRY-DESIGN.md` §2/§3).

   For a `kind = "exec"` entry, `gate run` is a NEW WAY TO INVOKE a gate
   script, not a new way for a gate to behave: every assertion in the script
   and the meaning of every exit code it returns are untouched, and
   `sh test/run_gates.sh` remains authoritative.  A `kind = "native"` entry has
   no script at all — `gate run` compiles and runs its `_test.mdk` module
   directly (`medaka test --native --json`) and grades the JSON envelope, so
   for THAT kind `gate run` is the gate's only way to run, not a wrapper around
   one.  Either way, what `gate run` adds around the underlying execution is the
   SAME set of SERVICES — scratch-dir lifecycle, the stale-oracle refusal (exec
   only), a timeout, separated stdout/stderr capture, and a machine-readable
   timing report — provided once, natively, instead of re-hand-rolled per gate.
   See the `gate run` section below. -}

import json.{
  Json,
  JString,
  JInt,
  JFloat,
  JBool,
  jArray,
  jObject,
  stringify,
  parse as parseJson,
  get as jsonGet,
  asInt as jsonAsInt,
}
import driver.build_cmd.{envOr, defaultMedakaRoot}
import driver.loader.{readDeps}
import support.path.{joinPath}
import io.{runCommandOk}
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
import tools.gate_registry.{
  Gate,
  Shard,
  Selector,
  parseRegistry,
  parseShards,
  globMatch,
  parseSelector,
  tierPartOf,
  modePartOf,
  selectGates,
  renderJson,
  renderShardsJson,
  renderShards,
  renderNames,
  joinSpace,
}
import tools.gate_pack.{
  balNewText,
  budgetOutput,
  timeoutFor,
}
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
  "implies, (c) the projected pole/floor (the same number `gate balance\n",
  "--check` derives) exceeds S-4's budget, or (d) a baseline row names no\n",
  "gate the registry currently declares. Any violation may be accepted on\n",
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
-- `vacuous` is set only for a `kind = "native"` gate whose `--json` summary
-- shows zero assertions of any kind (no doctests, no props, no `test "…"`
-- decls matched) — the exit-code-only contract this record used to carry
-- cannot distinguish that from "ran and passed", so `medaka test --native
-- --json`'s own summary is parsed to tell the two apart (#2633).
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
  vacuous : Bool,
}

-- Everything a gate invocation needs that is the same for every gate in a run.
data RunEnv = RunEnv {
  root : String,
  medaka : String,
  emitter : String,
  scratchRoot : String,
  timeoutOverride : Int,
}

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
  Ok _ => match runCommandOk "mktemp" ["-d", "\{root}/medaka_gate_XXXXXX"]
    Err e => Err e
    Ok (out, _) =>
      let d = stringTrim out
      if d == "" then Err "mktemp -d printed no path" else Ok d

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
scrapedOraclesIn scriptPath =
  match runCommand "grep" ["-ohE", "test/bin/[a-z_0-9]+", scriptPath]
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
gateArgs : RunEnv -> String -> Int -> List String -> List String
gateArgs env scratch secs cmd =
  "MEDAKA_ROOT=\{env.root}"
    :: "MEDAKA=\{env.medaka}"
    :: "MEDAKA_EMITTER=\{env.emitter}"
    :: "TMPDIR=\{scratch}"
    :: "MEDAKA_SCRATCH=\{scratch}"
    :: "JOBS=1"
    :: "timeout"
    :: "-k"
    :: "5s"
    :: "\{intToString secs}s"
    :: cmd

-- What runs a gate, and the label its result lines carry.
--
-- `kind = "exec"` is a script, so the interpreter comes from its shebang
-- (shellFor).  `kind = "native"` is a `*_test.mdk` module run by the compiler's
-- own test runner: `medaka test --native --json` exits 0 both when every
-- `test`/doctest/prop declaration passed AND when the module has none to run
-- at all (or `--filter` matched nothing) — exit code alone cannot tell those
-- two apart, so `runOneGate` also parses the `--json` summary to set
-- `GateResult.vacuous`, and `gateOk` reads both (#2633).
gateInvocation : RunEnv -> Gate -> String -> <IO> (String, List String)
gateInvocation env g script =
  if g.kind == "native" then
    ("medaka test --native", [env.medaka, "test", "--native", "--json", script])
  else
    let sh = shellFor script
    (sh, [sh, script])

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
  vacuous = False,
}

-- The `passed`/`failed` counts from a `medaka test --native --json`
-- envelope's `summary` object, or `None` when the output isn't that shape
-- (not JSON, or missing either field) — which this treats as "can't tell",
-- never as vacuous, so a native gate that fails before it can print a
-- summary is reported through its exit code exactly as before, not
-- misreported as vacuous.
nativeSummaryCounts : String -> Option (Int, Int)
nativeSummaryCounts out = match parseJson (stringTrim out)
  Err _ => None
  Ok j => summaryPassFail j

summaryPassFail : Json -> Option (Int, Int)
summaryPassFail j = do
  summary <- jsonGet "summary" j
  pj <- jsonGet "passed" summary
  fj <- jsonGet "failed" summary
  p <- jsonAsInt pj
  f <- jsonAsInt fj
  Some (p, f)

-- A `kind = "native"` gate is vacuous when it exited 0 (so `gateInvocation`'s
-- exit-code contract is satisfied) but its own `--json` summary shows zero
-- assertions ran — the case `--filter`-matched-nothing and the zero-`test`-decl
-- case both collapse into (#2633).
nativeVacuous : Gate -> Int -> String -> Bool
nativeVacuous g code out =
  g.kind == "native"
    && code == 0
    && (match nativeSummaryCounts out
      Some (0, 0) => True
      _ => False)

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
    let (sh, cmd) = gateInvocation env g script
    let secs = timeoutFor env.timeoutOverride g.cost
    match makeGateScratch env.scratchRoot
      Err e => spawnFailure g script "could not create a scratch dir: \{e}" 0.0
      Ok scratch =>
        let t0 = monotonicSec ()
        let res = runCommand "env" (gateArgs env scratch secs cmd)
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
            vacuous = nativeVacuous g code out,
          }

gateOk : GateResult -> Bool
gateOk r = r.spawnError == "" && r.exitCode == 0 && not r.vacuous

msOf : GateResult -> Int
msOf r = floatToInt (r.seconds * 1000.0)

resultLine : GateResult -> String
resultLine r
  | r.spawnError /= "" = "ERROR \{r.name}  (\{r.spawnError})\n"
  | r.timedOut =
    "TIMEOUT \{r.name}  (exit \{intToString r.exitCode} after \{intToString (msOf r)}ms)\n"
  | r.vacuous =
    "FAIL  \{r.name}  (vacuous: no doctests/props/`test \"…\"` ran, \{intToString (msOf r)}ms)\n"
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
-- dropped off the head of `splitNl`'s list and rejoined: one pass over the
-- string, no intermediate list, for a 200-line output bound.
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
  ("vacuous", JBool r.vacuous),
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
  let (sh, _cmd) =
    if fileExists script then gateInvocation env g script else ("sh", [])
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
-- no build — runs everywhere, cheap.  Each check is its own violation class:
--
--   1. every gate CANDIDATE — test/preflight.sh's own `_gate_candidates`
--      (tracked-or-untracked `*.sh`, MINUS every name in
--      test/CI-COVERAGE-TOOLS.txt) — is ENROLLED (some entry's `run` equals
--      its path) or excluded there.  No third state.  This runs the SAME two
--      `git ls-files` calls preflight's own `_gate_candidates` does, rather
--      than re-deriving the universe — see the packet's own warning: any
--      drift here would make `verify` green over a corpus S-2 already
--      reconciled, proving nothing.  One deliberate difference from
--      preflight's copy: `_gate_candidates` also drops a candidate with
--      `[ -f "$ROOT/$_rel" ] || continue` (a path tracked in the index but
--      absent from the working tree, e.g. deleted-but-uncommitted);
--      `gateCandidates` below applies no such filter, so a candidate can
--      surface here that preflight would already have dropped.  Check 2
--      below (`run` target exists on disk) still catches the same case for
--      any REGISTERED gate, so the only exposure is an unenrolled candidate
--      of this exact shape — narrow enough that this is a stated, not a
--      silent, gap.
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
--   6-11. entry names are unique, safe to interpolate into ci.yml and a shell
--      word, and `cost`, `tiers` and `migration` carry declared values; a
--      `shell:*` migration is paired with its run script's own
--      `shell-because:` header.  Each is written up at its definition below.
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
gitLsFilesSh : String ->
  List String ->
  String ->
  <IO> Result String (List String)
gitLsFilesSh root args pattern =
  match runCommandOk "git" (["-C", root] ++ args ++ [pattern])
    Err e => Err "git ls-files failed: \{e}"
    Ok (out, _) => Ok (filterList nonBlank (splitNl out))

-- Every candidate for ONE glob pattern, tracked or untracked.
candidatesFor : String -> String -> <IO> Result String (List String)
candidatesFor root pattern = match gitLsFilesSh root ["ls-files"] pattern
  Err m => Err m
  Ok tracked =>
    map
      (tracked ++ _)
      (gitLsFilesSh root ["ls-files", "-o", "--exclude-standard"] pattern)

-- Check 1's candidate universe: every `.sh` (the original corpus) PLUS every
-- `test/*_test.mdk` — the [P-TEST-SIBLING] native-gate naming convention
-- (`compiler/types/registry_test.mdk` tests `registry.mdk`; a gate's own
-- `run` module lives at `test/<name>_test.mdk`, e.g.
-- `test/effect_set_domain_test.mdk`) — so a native test module nobody
-- enrolled is flagged exactly like an unenrolled `.sh` script, rather than
-- silently invisible to `gate verify` the way check 1 used to be (#2633).
-- git's pathspec glob does NOT stop `*` at `/` (`test/*_test.mdk` matches
-- `test/construct_fixtures/prop_test.mdk`, a data fixture some OTHER gate
-- reads, not a gate module of its own) — measured:
-- `git ls-files 'test/*_test.mdk'`, so the glob's matches are narrowed to the
-- top level of `test/` before joining the `.sh` candidates.
--
-- That narrowing bounds the census rather than describing every native gate.
-- A project's floor gate is a native `run` under its OWN `test/` directory
-- (`mq/test/check_test.mdk`, #2592), which this corpus does not reach and so
-- gets no orphan protection. Widening to `*/test/*_test.mdk` would reach it
-- and would also sweep in ~29 `pds/test/*_test.mdk` and `sqlite/test/*_test.mdk`
-- modules that are in-language test suites some project gate RUNS, not gates
-- of their own — none is any entry's `run`, so every one would report
-- unenrolled. A census cannot tell those two apart by path, so it stops where
-- it can still be right.
directlyUnderTest : String -> Bool
directlyUnderTest p = listLen (splitOnChar '/' p) == 2

gateCandidates : String -> <IO> Result String (List String)
gateCandidates root = match candidatesFor root "*.sh"
  Err m => Err m
  Ok shScripts =>
    map
      (nativeTests =>
        sortUniqS (shScripts ++ filterList directlyUnderTest nativeTests))
      (candidatesFor root "test/*_test.mdk")

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
knownOracles root =
  match runCommand "sh" ["\{root}/test/build_oracles.sh", "--list"]
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

-- Check 10 (#2591): every entry's `migration` is one of the eight destinations
-- the schema comment in `compiler/tools/gate_registry.mdk` defines.  `migration` is a required TOML string with
-- no enum check at parse time, exactly like `cost` before check 8 — and a
-- migration value nothing recognizes is worse than a typo'd cost, because the
-- whole point of the field is that a wave of the epic can select on it.  A
-- misspelled destination selects into no wave and reads as "already handled".
migrationClassOk : String -> Bool
migrationClassOk m =
  m == "native-wrap"
    || m == "native-rewrite"
    || m == "shell:trust-anchor"
    || m == "shell:instrumentation"
    || m == "shell:external-harness"
    || m == "split-first"
    || m == "inverted-polarity"
    || m == "done"

migrationClassNames : String
migrationClassNames =
  "native-wrap/native-rewrite/shell:trust-anchor/shell:instrumentation/shell:external-harness/split-first/inverted-polarity/done"

invalidMigrationViolations : List Gate -> List String
invalidMigrationViolations [] = []
invalidMigrationViolations (g :: gs)
  | migrationClassOk g.migration = invalidMigrationViolations gs
  | otherwise =
    "\{g.name}: migration '\{g.migration}' is not one of \{migrationClassNames}"
      :: invalidMigrationViolations gs

-- Check 11 (#2591): the `shell-because:` pairing.  A `shell:*` migration is an
-- EXEMPTION — this gate is never going native — and an exemption one side
-- grants itself is not reviewable.  So the reason has to be stated where the
-- reader of the exempted thing will see it: the `run` script carries a
-- `shell-because: <class> …` header line, and it must name the SAME class the
-- registry does.  A mismatch is the interesting failure — a script that stops
-- being a trust anchor and becomes ordinary would otherwise keep its exemption
-- with nothing anywhere disagreeing.
shellBecauseTag : String
shellBecauseTag = "shell-because:"

-- The class a `shell:*` value names (`trust-anchor`), or `""` for every other
-- migration value — the "this entry needs no header" answer.
shellClassOf : String -> String
shellClassOf m =
  if startsWith "shell:" m then
    stringSlice (stringLength "shell:") (stringLength m) m
  else
    ""

-- A comment line's text with its leading `#`s and spaces removed.  The header
-- is a shell comment, so the tag never starts the raw line.
stripHash : String -> String
stripHash s =
  let t = stringTrim s
  if startsWith "#" t then stripHash (stringSlice 1 (stringLength t) t) else t

-- The class token of a `shell-because:` line, or `None` if the line is not one.
-- `firstToken` (check 1's helper) takes the first whitespace-separated word, so
-- the rest of the line is free prose.
becauseClassOf : String -> Option String
becauseClassOf line =
  let t = stripHash line
  if startsWith shellBecauseTag t then
    Some
      (firstToken
        (stringTrim
          (stringSlice (stringLength shellBecauseTag) (stringLength t) t)))
  else
    None

becauseClasses : List String -> List String
becauseClasses [] = []
becauseClasses (l :: ls) = match becauseClassOf l
  Some c => c :: becauseClasses ls
  None => becauseClasses ls

shellBecauseErrors : String -> Gate -> <IO> List String
shellBecauseErrors root g =
  let want = shellClassOf g.migration
  if want == "" then
    []
  else match readFile (joinPath root g.run)
    Err m => [
      "\{g.name}: migration '\{g.migration}' but its run script cannot be read to confirm the reason: \{g.run}: \{m}",
    ]
    Ok src => match becauseClasses (splitNl src)
      [] => [
        "\{g.name}: migration '\{g.migration}' but \{g.run} carries no 'shell-because: \{want}' header line — a stays-shell exemption the script itself never states",
      ]
      c :: _ =>
        if c == want then
          []
        else
          [
            "\{g.name}: migration '\{g.migration}' but \{g.run} states 'shell-because: \{c}' — registry and script name different reason classes",
          ]

shellBecauseViolations : String -> List Gate -> <IO> List String
shellBecauseViolations _ [] = []
shellBecauseViolations root (g :: gs) =
  shellBecauseErrors root g ++ shellBecauseViolations root gs

-- ── assembling and rendering the violation classes ──────────────────────────

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
      ("invalid migration class", invalidMigrationViolations gates),
      ("unpaired shell-because", shellBecauseViolations root gates),
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
-- two gates, diff_compiler_source_bytes and diff_compiler_comment_shout_diff
-- (#2621), each of which re-scans every tracked file whatever changed).  It
-- matches every path by construction, so it must never establish that a path
-- is MAPPED — otherwise layer 1's fail-open could never fire again and an
-- unmapped path would silently select one whole-tree gate instead of the
-- suite.  preflight draws exactly this line too: its unconditional `add` for
-- each of the two sits OUTSIDE the case table whose misses it reports as
-- UNMAPPED.
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

-- A gate's own `run` module is an implicit source: editing it is editing what
-- the gate most directly asserts, whether or not any `sources` glob happens
-- to also cover it (#2822) — a `sources` coincidence is not a design.
runMatches : String -> Gate -> List String
runMatches path g = if path == g.run then ["run:\{g.run}"] else []

targetedReasons : String -> Gate -> List String
targetedReasons path g =
  sourceMatches path g.sources
    ++ corpusMatches path g.corpus
    ++ runMatches path g

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
ciCmdBody argv = match parseCiArgs argv CiArgs {
  registry = None,
  workflow = None,
  check = False,
}
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
balCmdBody argv = match parseBalArgs argv BalArgs {
  registry = None,
  baseline = None,
  check = False,
}
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
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false) (mem "parse" false "parseJson") (mem "get" false "jsonGet") (mem "asInt" false "jsonAsInt"))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "readDeps" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("io") ((mem "runCommandOk" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "Trailing" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "withTrailing" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "unknownFlagMessage" false) (mem "missingValueMessage" false))))
(DUse false (UseGroup ("tools" "gate_registry") ((mem "Gate" false) (mem "Shard" false) (mem "Selector" false) (mem "parseRegistry" false) (mem "parseShards" false) (mem "globMatch" false) (mem "parseSelector" false) (mem "tierPartOf" false) (mem "modePartOf" false) (mem "selectGates" false) (mem "renderJson" false) (mem "renderShardsJson" false) (mem "renderShards" false) (mem "renderNames" false) (mem "joinSpace" false))))
(DUse false (UseGroup ("tools" "gate_pack") ((mem "balNewText" false) (mem "budgetOutput" false) (mem "timeoutFor" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate reach   [<changed-path>...] [--paths-from <file>] [--json]\n")) (ELit (LString "                      [--registry <path>] [--root <path>]\n")) (ELit (LString "  medaka gate ci      [--check] [--registry <path>] [--workflow <path>]\n")) (ELit (LString "  medaka gate balance [--check] [--registry <path>] [--baseline <path>]\n")) (ELit (LString "  medaka gate budget  [--registry <path>] [--baseline <path>]\n")) (ELit (LString "                      [--commit-message <text>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      a RUN of this gate: merge | nightly | ondemand, optionally\n")) (ELit (LString "                   /<mode> (the invocation delta, e.g. nightly/PERF_DEEP=1).\n")) (ELit (LString "                   A gate can have several; the glob matches a whole token or\n")) (ELit (LString "                   its tier part, so tier:nightly selects every mode.\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` only:\n")) (ELit (LString "  --check            derive the assignment in memory and report whether the\n")) (ELit (LString "                     committed one matches it; write nothing\n")) (ELit (LString "  --baseline <path>  read this cost baseline instead of\n")) (ELit (LString "                     <MEDAKA_ROOT>/test/gate_cost_baseline.json\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` CHOOSES each gate's `shard` row from the registry's own\n")) (ELit (LString "constraints plus the measured cost baseline, and rewrites the `shard = \"...\"`\n")) (ELit (LString "lines in test/gates.toml in place. A full_cores row is CLOSED: its members\n")) (ELit (LString "are declared by that [[shard]] row's `pinned_gates` and checked in both\n")) (ELit (LString "directions, so they are neither packed nor hand-assignable. A gate needing\n")) (ELit (LString "wasm-tools/node only lands on a\n")) (ELit (LString "row with wasm_arm = true. It refuses rather than pack from a missing cost,\n")) (ELit (LString "and fails when the assignment it would emit misses its pole/floor budget.\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, no two entries\n")) (ELit (LString "share a `name`, and every entry's `cost` and `tiers` are well formed.\n")) (ELit (LString "Exits nonzero on any violation. It checks the SHAPE of `tiers`, not\n")) (ELit (LString "whether it agrees with the workflows — that is\n")) (ELit (LString "test/diff_compiler_tier_drift.sh, which reads the workflow YAML.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`.\n")) (ELit (LString "\n")) (ELit (LString "  --check            ci: compare only — compute the generated text and\n")) (ELit (LString "                     compare it IN MEMORY to the file on disk, writing\n")) (ELit (LString "                     nothing. Exit 0 when they agree, 1 with the first\n")) (ELit (LString "                     differing line when they do not. This is the drift\n")) (ELit (LString "                     check; regenerating first would heal an uncommitted\n")) (ELit (LString "                     hand-edit before any diff could see it, and diffing\n")) (ELit (LString "                     the whole file would also fire on an edit OUTSIDE\n")) (ELit (LString "                     the generated region.\n")) (ELit (LString "\n")) (ELit (LString "The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")) (ELit (LString "\n")) (ELit (LString "`gate reach <changed-path>...` is the QUEUE's project scoping (#2179):\n")) (ELit (LString "which projects must run their gates for an entry touching those paths.\n")) (ELit (LString "A path under <project>/ selects that project, plus every project whose\n")) (ELit (LString "medaka.toml [dependencies] reaches it, plus the owning project of every\n")) (ELit (LString "gate whose `corpus` names a selected project. An empty list, a compiler/\n")) (ELit (LString "or stdlib/ path, and any path no project directory claims all FAIL OPEN\n")) (ELit (LString "to every project: this command never answers `nothing`.\n")) (ELit (LString "\n")) (ELit (LString "`gate budget` is #2180's governor: text-only, no build. Reds when (a) a\n")) (ELit (LString "schedulable gate has no cost baseline entry, (b) a gate's measured cost\n")) (ELit (LString "has eaten into the tolerance-adjusted timeout its declared `cost` class\n")) (ELit (LString "implies, (c) the projected pole/floor (the same number `gate balance\n")) (ELit (LString "--check` derives) exceeds S-4's budget, or (d) a baseline row names no\n")) (ELit (LString "gate the registry currently declares. Any violation may be accepted on\n")) (ELit (LString "purpose with a `Gate-Budget-Override: <token>` trailer on the commit\n")) (ELit (LString "message (there is no PR body in a merge_group run) — the failing gate\n")) (ELit (LString "prints the exact trailer to paste.\n")) (ELit (LString "\n")) (ELit (LString "  --commit-message <text>  budget: the commit message to scan for\n")) (ELit (LString "                     `Gate-Budget-Override:` trailers. Omit for none.\n")))))
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
(DData Public "GateResult" () ((variant "GateResult" (ConNamed (field "name" (TyCon "String")) (field "script" (TyCon "String")) (field "shell" (TyCon "String")) (field "exitCode" (TyCon "Int")) (field "timedOut" (TyCon "Bool")) (field "spawnError" (TyCon "String")) (field "seconds" (TyCon "Float")) (field "out" (TyCon "String")) (field "err" (TyCon "String")) (field "vacuous" (TyCon "Bool"))))) ())
(DData Private "RunEnv" () ((variant "RunEnv" (ConNamed (field "root" (TyCon "String")) (field "medaka" (TyCon "String")) (field "emitter" (TyCon "String")) (field "scratchRoot" (TyCon "String")) (field "timeoutOverride" (TyCon "Int"))))) ())
(DTypeSig false "scratchRootOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "scratchRootOf" (PWild) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "TMPDIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EBinOp "/=" (EApp (EVar "stripSlash") (EVar "t")) (ELit (LString "/tmp")))) (EVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_SCRATCH"))) (ELit (LString "/var/tmp/medaka-scratch")))))))
(DTypeSig false "stripSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSlash" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "/")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeGateScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeGateScratch" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "root"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/medaka_gate_XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "d") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "d"))))))))))
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
(DTypeSig false "gateArgs" (TyFun (TyCon "RunEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "gateArgs" ((PVar "env") (PVar "scratch") (PVar "secs") (PVar "cmd")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "medaka"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EVar "display") (EFieldAccess (EVar "env") "emitter"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "TMPDIR=")) (EApp (EVar "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_SCRATCH=")) (EApp (EVar "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "::" (ELit (LString "JOBS=1")) (EBinOp "::" (ELit (LString "timeout")) (EBinOp "::" (ELit (LString "-k")) (EBinOp "::" (ELit (LString "5s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "s"))) (EVar "cmd"))))))))))))
(DTypeSig false "gateInvocation" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gateInvocation" ((PVar "env") (PVar "g") (PVar "script")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "kind") (ELit (LString "native"))) (ETuple (ELit (LString "medaka test --native")) (EListLit (EFieldAccess (EVar "env") "medaka") (ELit (LString "test")) (ELit (LString "--native")) (ELit (LString "--json")) (EVar "script"))) (EBlock (DoLet false false (PVar "sh") (EApp (EVar "shellFor") (EVar "script"))) (DoExpr (ETuple (EVar "sh") (EListLit (EVar "sh") (EVar "script")))))))
(DTypeSig false "spawnFailure" (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyCon "GateResult"))))))
(DFunDef false "spawnFailure" ((PVar "g") (PVar "script") (PVar "msg") (PVar "dt")) (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (ELit (LString "sh"))) (fa "exitCode" (ELit (LInt 127))) (fa "timedOut" (EVar "False")) (fa "spawnError" (EVar "msg")) (fa "seconds" (EVar "dt")) (fa "out" (ELit (LString ""))) (fa "err" (ELit (LString ""))) (fa "vacuous" (EVar "False")))))
(DTypeSig false "nativeSummaryCounts" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nativeSummaryCounts" ((PVar "out")) (EMatch (EApp (EVar "parseJson") (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "j")) () (EApp (EVar "summaryPassFail") (EVar "j")))))
(DTypeSig false "summaryPassFail" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "summaryPassFail" ((PVar "j")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "summary"))) (EVar "j"))) (ELam ((PVar "summary")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "passed"))) (EVar "summary"))) (ELam ((PVar "pj")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "failed"))) (EVar "summary"))) (ELam ((PVar "fj")) (EApp (EApp (EVar "andThen") (EApp (EVar "jsonAsInt") (EVar "pj"))) (ELam ((PVar "p")) (EApp (EApp (EVar "andThen") (EApp (EVar "jsonAsInt") (EVar "fj"))) (ELam ((PVar "f")) (EApp (EVar "Some") (ETuple (EVar "p") (EVar "f"))))))))))))))
(DTypeSig false "nativeVacuous" (TyFun (TyCon "Gate") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "nativeVacuous" ((PVar "g") (PVar "code") (PVar "out")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "g") "kind") (ELit (LString "native"))) (EBinOp "==" (EVar "code") (ELit (LInt 0)))) (EMatch (EApp (EVar "nativeSummaryCounts") (EVar "out")) (arm (PCon "Some" (PTuple (PLit (LInt 0)) (PLit (LInt 0)))) () (EVar "True")) (arm PWild () (EVar "False")))))
(DTypeSig false "runOneGate" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "GateResult")))))
(DFunDef false "runOneGate" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "script"))) (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "gate script not found (registry `run` field): ")) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (ELit (LFloat 0.0))) (EBlock (DoLet false false (PTuple (PVar "sh") (PVar "cmd")) (EApp (EApp (EApp (EVar "gateInvocation") (EVar "env")) (EVar "g")) (EVar "script"))) (DoLet false false (PVar "secs") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))) (DoExpr (EMatch (EApp (EVar "makeGateScratch") (EFieldAccess (EVar "env") "scratchRoot")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not create a scratch dir: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LFloat 0.0)))) (arm (PCon "Ok" (PVar "scratch")) () (EBlock (DoLet false false (PVar "t0") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EApp (EApp (EApp (EApp (EVar "gateArgs") (EVar "env")) (EVar "scratch")) (EVar "secs")) (EVar "cmd")))) (DoLet false false (PVar "dt") (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "t0"))) (DoLet false false PWild (EApp (EVar "cleanupScratch") (EVar "scratch"))) (DoExpr (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not spawn the gate: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "dt"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (EVar "sh")) (fa "exitCode" (EVar "code")) (fa "timedOut" (EBinOp "||" (EBinOp "==" (EVar "code") (ELit (LInt 124))) (EBinOp "==" (EVar "code") (ELit (LInt 137))))) (fa "spawnError" (ELit (LString ""))) (fa "seconds" (EVar "dt")) (fa "out" (EVar "out")) (fa "err" (EVar "errOut")) (fa "vacuous" (EApp (EApp (EApp (EVar "nativeVacuous") (EVar "g")) (EVar "code")) (EVar "out")))))))))))))))))
(DTypeSig false "gateOk" (TyFun (TyCon "GateResult") (TyCon "Bool")))
(DFunDef false "gateOk" ((PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0)))) (EApp (EVar "not") (EFieldAccess (EVar "r") "vacuous"))))
(DTypeSig false "msOf" (TyFun (TyCon "GateResult") (TyCon "Int")))
(DFunDef false "msOf" ((PVar "r")) (EApp (EVar "floatToInt") (EBinOp "*" (EFieldAccess (EVar "r") "seconds") (ELit (LFloat 1000.0)))))
(DTypeSig false "resultLine" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "resultLine" ((PVar "r")) (EIf (EBinOp "/=" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EVar "display") (EFieldAccess (EVar "r") "spawnError"))) (ELit (LString ")\n"))) (EIf (EFieldAccess (EVar "r") "timedOut") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TIMEOUT ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString " after "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EFieldAccess (EVar "r") "vacuous") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (vacuous: no doctests/props/`test \"…\"` ran, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PASS  ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
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
(DFunDef false "resultJson" ((PVar "r")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "name"))) (ETuple (ELit (LString "script")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "script"))) (ETuple (ELit (LString "shell")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "shell"))) (ETuple (ELit (LString "exit")) (EApp (EVar "JInt") (EFieldAccess (EVar "r") "exitCode"))) (ETuple (ELit (LString "timedOut")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "timedOut"))) (ETuple (ELit (LString "ms")) (EApp (EVar "JInt") (EApp (EVar "msOf") (EVar "r")))) (ETuple (ELit (LString "seconds")) (EApp (EVar "JFloat") (EFieldAccess (EVar "r") "seconds"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EVar "gateOk") (EVar "r")))) (ETuple (ELit (LString "vacuous")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "vacuous"))) (ETuple (ELit (LString "spawnError")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "spawnError"))) (ETuple (ELit (LString "stdout")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "out"))) (ETuple (ELit (LString "stderr")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "err"))))))
(DTypeSig true "runReportJson" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "runReportJson" ((PVar "jobs") (PVar "rs")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jobs")) (EApp (EVar "JInt") (EVar "jobs"))) (ETuple (ELit (LString "parallel")) (EApp (EVar "JBool") (EVar "False"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JInt") (EApp (EVar "countOk") (EVar "rs")))) (ETuple (ELit (LString "failing")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EApp (EVar "countOk") (EVar "rs"))))) (ETuple (ELit (LString "gates")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "resultJson")) (EVar "rs"))))))))
(DTypeSig false "dryLine" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLine" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoLet false false (PTuple (PVar "sh") (PVar "_cmd")) (EIf (EApp (EVar "fileExists") (EVar "script")) (EApp (EApp (EApp (EVar "gateInvocation") (EVar "env")) (EVar "g")) (EVar "script")) (ETuple (ELit (LString "sh")) (EListLit)))) (DoLet false false (PVar "orc") (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "oracles")) (ELit (LString "-")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "g") "oracles")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "sh"))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "script"))) (ELit (LString "\ttimeout="))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s\toracles="))) (EApp (EVar "display") (EVar "orc"))) (ELit (LString "\n"))))))
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
(DTypeSig false "gitLsFilesSh" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gitLsFilesSh" ((PVar "root") (PVar "args") (PVar "pattern")) (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "git"))) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "-C")) (EVar "root")) (EVar "args")) (EListLit (EVar "pattern")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out")))))))
(DTypeSig false "candidatesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "candidatesFor" ((PVar "root") (PVar "pattern")) (EMatch (EApp (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")))) (EVar "pattern")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "tracked")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "tracked") (EVar "_s")))) (EApp (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")) (ELit (LString "-o")) (ELit (LString "--exclude-standard")))) (EVar "pattern"))))))
(DTypeSig false "directlyUnderTest" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "directlyUnderTest" ((PVar "p")) (EBinOp "==" (EApp (EVar "listLen") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "p"))) (ELit (LInt 2))))
(DTypeSig false "gateCandidates" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateCandidates" ((PVar "root")) (EMatch (EApp (EApp (EVar "candidatesFor") (EVar "root")) (ELit (LString "*.sh"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "shScripts")) () (EApp (EApp (EVar "map") (ELam ((PVar "nativeTests")) (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "shScripts") (EApp (EApp (EVar "filterList") (EVar "directlyUnderTest")) (EVar "nativeTests")))))) (EApp (EApp (EVar "candidatesFor") (EVar "root")) (ELit (LString "test/*_test.mdk")))))))
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
(DTypeSig false "migrationClassOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "migrationClassOk" ((PVar "m")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "m") (ELit (LString "native-wrap"))) (EBinOp "==" (EVar "m") (ELit (LString "native-rewrite")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:trust-anchor")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:instrumentation")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:external-harness")))) (EBinOp "==" (EVar "m") (ELit (LString "split-first")))) (EBinOp "==" (EVar "m") (ELit (LString "inverted-polarity")))) (EBinOp "==" (EVar "m") (ELit (LString "done")))))
(DTypeSig false "migrationClassNames" (TyCon "String"))
(DFunDef false "migrationClassNames" () (ELit (LString "native-wrap/native-rewrite/shell:trust-anchor/shell:instrumentation/shell:external-harness/split-first/inverted-polarity/done")))
(DTypeSig false "invalidMigrationViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidMigrationViolations" ((PList)) (EListLit))
(DFunDef false "invalidMigrationViolations" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "migrationClassOk") (EFieldAccess (EVar "g") "migration")) (EApp (EVar "invalidMigrationViolations") (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' is not one of "))) (EApp (EVar "display") (EVar "migrationClassNames"))) (ELit (LString ""))) (EApp (EVar "invalidMigrationViolations") (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shellBecauseTag" (TyCon "String"))
(DFunDef false "shellBecauseTag" () (ELit (LString "shell-because:")))
(DTypeSig false "shellClassOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "shellClassOf" ((PVar "m")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "shell:"))) (EVar "m")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (ELit (LString "shell:")))) (EApp (EVar "stringLength") (EVar "m"))) (EVar "m")) (ELit (LString ""))))
(DTypeSig false "stripHash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripHash" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "s"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "#"))) (EVar "t")) (EApp (EVar "stripHash") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))) (EVar "t")))))
(DTypeSig false "becauseClassOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "becauseClassOf" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stripHash") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "shellBecauseTag")) (EVar "t")) (EApp (EVar "Some") (EApp (EVar "firstToken") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "shellBecauseTag"))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))))) (EVar "None")))))
(DTypeSig false "becauseClasses" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "becauseClasses" ((PList)) (EListLit))
(DFunDef false "becauseClasses" ((PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EVar "becauseClassOf") (EVar "l")) (arm (PCon "Some" (PVar "c")) () (EBinOp "::" (EVar "c") (EApp (EVar "becauseClasses") (EVar "ls")))) (arm (PCon "None") () (EApp (EVar "becauseClasses") (EVar "ls")))))
(DTypeSig false "shellBecauseErrors" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "shellBecauseErrors" ((PVar "root") (PVar "g")) (EBlock (DoLet false false (PVar "want") (EApp (EVar "shellClassOf") (EFieldAccess (EVar "g") "migration"))) (DoExpr (EIf (EBinOp "==" (EVar "want") (ELit (LString ""))) (EListLit) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "g") "run"))) (arm (PCon "Err" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but its run script cannot be read to confirm the reason: "))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "becauseClasses") (EApp (EVar "splitNl") (EVar "src"))) (arm (PList) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but "))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString " carries no 'shell-because: "))) (EApp (EVar "display") (EVar "want"))) (ELit (LString "' header line — a stays-shell exemption the script itself never states"))))) (arm (PCons (PVar "c") PWild) () (EIf (EBinOp "==" (EVar "c") (EVar "want")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EVar "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but "))) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString " states 'shell-because: "))) (EApp (EVar "display") (EVar "c"))) (ELit (LString "' — registry and script name different reason classes")))))))))))))
(DTypeSig false "shellBecauseViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "shellBecauseViolations" (PWild (PList)) (EListLit))
(DFunDef false "shellBecauseViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "shellBecauseErrors") (EVar "root")) (EVar "g")) (EApp (EApp (EVar "shellBecauseViolations") (EVar "root")) (EVar "gs"))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))) (ETuple (ELit (LString "unsafe entry names")) (EApp (EApp (EVar "unsafeNameViolations") (EVar "gates")) (EVar "shs"))) (ETuple (ELit (LString "invalid cost class")) (EApp (EVar "invalidCostViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid tiers")) (EApp (EVar "invalidTiersViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid migration class")) (EApp (EVar "invalidMigrationViolations") (EVar "gates"))) (ETuple (ELit (LString "unpaired shell-because")) (EApp (EApp (EVar "shellBecauseViolations") (EVar "root")) (EVar "gates"))))))))))
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
(DTypeSig false "runMatches" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "runMatches" ((PVar "path") (PVar "g")) (EIf (EBinOp "==" (EVar "path") (EFieldAccess (EVar "g") "run")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "run:")) (EApp (EVar "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "targetedReasons" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "targetedReasons" ((PVar "path") (PVar "g")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EFieldAccess (EVar "g") "sources")) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EFieldAccess (EVar "g") "corpus"))) (EApp (EApp (EVar "runMatches") (EVar "path")) (EVar "g"))))
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
(DTypeSig false "balWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "balWrite" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString " already balanced — no shard assignment changed\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "regPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: cannot write "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: rewrote the shard assignments in "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "balCheckResult" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString " already balanced\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EVar "head") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": the committed shard assignment is not the\n"))) (ELit (LString "one the balancer derives from test/gate_cost_baseline.json.  A `shard` field\n")) (ELit (LString "is DERIVED DATA (#2178): it is not hand-editable, and a hand edit that keeps\n")) (ELit (LString "ci.yml self-consistent is exactly what this check exists to catch.  First\n")) (ELit (LString "differing line:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "regSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'medaka gate balance' then 'make gen-ci', and commit both.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "balCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseBalArgs") (EVar "argv")) (ERecordCreate "BalArgs" ((fa "registry" (EVar "None")) (fa "baseline" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read cost baseline ")) (EApp (EVar "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EMatch (EApp (EApp (EApp (EVar "balNewText") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PTuple (PVar "head") (PVar "out"))) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "balCheckResult") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))) (EApp (EApp (EApp (EApp (EVar "balWrite") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))))))))))))))
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
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "JInt" false) (mem "JFloat" false) (mem "JBool" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false) (mem "parse" false "parseJson") (mem "get" false "jsonGet") (mem "asInt" false "jsonAsInt"))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "readDeps" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("io") ((mem "runCommandOk" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "Trailing" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "withTrailing" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "unknownFlagMessage" false) (mem "missingValueMessage" false))))
(DUse false (UseGroup ("tools" "gate_registry") ((mem "Gate" false) (mem "Shard" false) (mem "Selector" false) (mem "parseRegistry" false) (mem "parseShards" false) (mem "globMatch" false) (mem "parseSelector" false) (mem "tierPartOf" false) (mem "modePartOf" false) (mem "selectGates" false) (mem "renderJson" false) (mem "renderShardsJson" false) (mem "renderShards" false) (mem "renderNames" false) (mem "joinSpace" false))))
(DUse false (UseGroup ("tools" "gate_pack") ((mem "balNewText" false) (mem "budgetOutput" false) (mem "timeoutFor" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false) (mem "filterList" false) (mem "joinNl" false) (mem "joinWith" false) (mem "listLen" false) (mem "parseDecChecked" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list    [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate list    --shards [--json] [--registry <path>]\n")) (ELit (LString "  medaka gate run     [<selector>...] [--dry-run] [--json] [--report <path>]\n")) (ELit (LString "                      [--timeout <secs>] [--jobs <n>] [--no-stale-check]\n")) (ELit (LString "                      [--registry <path>]\n")) (ELit (LString "  medaka gate verify  [--registry <path>]\n")) (ELit (LString "  medaka gate explain <path> [--prose] [--registry <path>]\n")) (ELit (LString "  medaka gate reach   [<changed-path>...] [--paths-from <file>] [--json]\n")) (ELit (LString "                      [--registry <path>] [--root <path>]\n")) (ELit (LString "  medaka gate ci      [--check] [--registry <path>] [--workflow <path>]\n")) (ELit (LString "  medaka gate balance [--check] [--registry <path>] [--baseline <path>]\n")) (ELit (LString "  medaka gate budget  [--registry <path>] [--baseline <path>]\n")) (ELit (LString "                      [--commit-message <text>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      a RUN of this gate: merge | nightly | ondemand, optionally\n")) (ELit (LString "                   /<mode> (the invocation delta, e.g. nightly/PERF_DEEP=1).\n")) (ELit (LString "                   A gate can have several; the glob matches a whole token or\n")) (ELit (LString "                   its tier part, so tier:nightly selects every mode.\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             list: the registry entries as JSON.\n")) (ELit (LString "  --shards           list: the ci.yml `gates` matrix rows, not the gates.\n")) (ELit (LString "                     run: the machine-readable run report as JSON.\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` only:\n")) (ELit (LString "  --check            derive the assignment in memory and report whether the\n")) (ELit (LString "                     committed one matches it; write nothing\n")) (ELit (LString "  --baseline <path>  read this cost baseline instead of\n")) (ELit (LString "                     <MEDAKA_ROOT>/test/gate_cost_baseline.json\n")) (ELit (LString "\n")) (ELit (LString "`gate balance` CHOOSES each gate's `shard` row from the registry's own\n")) (ELit (LString "constraints plus the measured cost baseline, and rewrites the `shard = \"...\"`\n")) (ELit (LString "lines in test/gates.toml in place. A full_cores row is CLOSED: its members\n")) (ELit (LString "are declared by that [[shard]] row's `pinned_gates` and checked in both\n")) (ELit (LString "directions, so they are neither packed nor hand-assignable. A gate needing\n")) (ELit (LString "wasm-tools/node only lands on a\n")) (ELit (LString "row with wasm_arm = true. It refuses rather than pack from a missing cost,\n")) (ELit (LString "and fails when the assignment it would emit misses its pole/floor budget.\n")) (ELit (LString "\n")) (ELit (LString "`gate run` only:\n")) (ELit (LString "  --dry-run          print the resolved invocation plan; execute nothing\n")) (ELit (LString "  --report <path>    write the per-gate timing report (JSON) to <path>\n")) (ELit (LString "  --timeout <secs>   override the per-gate fuse (default by `cost`:\n")) (ELit (LString "                     cheap 300s, medium 900s, heavy 3600s)\n")) (ELit (LString "  --jobs <n>         ACCEPTED BUT IGNORED — this runner is sequential; the\n")) (ELit (LString "                     value is recorded in the report.  Medaka has no\n")) (ELit (LString "                     concurrency primitive (stdlib/runtime.mdk has no\n")) (ELit (LString "                     fork/waitpid) and runCommand blocks.\n")) (ELit (LString "  --no-stale-check   skip the stale-oracle refusal (as NO_STALE_CHECK=1 does;\n")) (ELit (LString "                     it is also skipped whenever CI is set, on purpose)\n")) (ELit (LString "\n")) (ELit (LString "`gate run` reports each gate's RAW exit code and never normalizes polarity:\n")) (ELit (LString "diff_compiler_must_fail is healthy when RED ([G-MUST-FAIL]).\n")) (ELit (LString "\n")) (ELit (LString "`gate verify` is the drift gate: text-only, no build. Checks every gate\n")) (ELit (LString "candidate (test/preflight.sh's own candidate universe) is enrolled or\n")) (ELit (LString "explicitly listed as a non-gate tool, every entry's run/oracles/corpus\n")) (ELit (LString "targets exist, every entry is reachable by a selector, no two entries\n")) (ELit (LString "share a `name`, and every entry's `cost` and `tiers` are well formed.\n")) (ELit (LString "Exits nonzero on any violation. It checks the SHAPE of `tiers`, not\n")) (ELit (LString "whether it agrees with the workflows — that is\n")) (ELit (LString "test/diff_compiler_tier_drift.sh, which reads the workflow YAML.\n")) (ELit (LString "\n")) (ELit (LString "`gate ci` regenerates the marked GENERATED region in\n")) (ELit (LString ".github/workflows/ci.yml — the `gates` job's eight-row matrix — from\n")) (ELit (LString "the registry's [[shard]] rows and every entry's `shard` field. Run it\n")) (ELit (LString "via `make gen-ci`.\n")) (ELit (LString "\n")) (ELit (LString "  --check            ci: compare only — compute the generated text and\n")) (ELit (LString "                     compare it IN MEMORY to the file on disk, writing\n")) (ELit (LString "                     nothing. Exit 0 when they agree, 1 with the first\n")) (ELit (LString "                     differing line when they do not. This is the drift\n")) (ELit (LString "                     check; regenerating first would heal an uncommitted\n")) (ELit (LString "                     hand-edit before any diff could see it, and diffing\n")) (ELit (LString "                     the whole file would also fire on an edit OUTSIDE\n")) (ELit (LString "                     the generated region.\n")) (ELit (LString "\n")) (ELit (LString "The named-gate steps in soundness/wasm are NOT\n")) (ELit (LString "generated — the registry cannot say which job runs which (see the\n")) (ELit (LString "`gate ci` section of compiler/tools/gate_cmd.mdk).\n")) (ELit (LString "\n")) (ELit (LString "`gate explain <path>` is the reverse lookup: which entries select a\n")) (ELit (LString "changed path, and why. Two layers, printed with preflight's own prefixes:\n")) (ELit (LString "the registry-level POLICY (FULL on a blast-radius path; UNMAPPED + FULL on\n")) (ELit (LString "an unmatched non-prose path; UNMAPPED alone on prose), then per-entry\n")) (ELit (LString "`sources` globs and `corpus` directories on GATE lines. A bare token that\n")) (ELit (LString "is also a field value (name/area/project/tier/run) gets TOKEN lines.\n")) (ELit (LString "\n")) (ELit (LString "`gate explain --prose <path>` prints ONLY layer 1b's verdict, `PROSE` or\n")) (ELit (LString "`NONDOC`, and reads no registry. It exists so that\n")) (ELit (LString "test/diff_compiler_prose_classifier.sh can diff this classifier against\n")) (ELit (LString "the one .github/workflows/ci.yml's `detect` job runs (#2200).\n")) (ELit (LString "\n")) (ELit (LString "`gate reach <changed-path>...` is the QUEUE's project scoping (#2179):\n")) (ELit (LString "which projects must run their gates for an entry touching those paths.\n")) (ELit (LString "A path under <project>/ selects that project, plus every project whose\n")) (ELit (LString "medaka.toml [dependencies] reaches it, plus the owning project of every\n")) (ELit (LString "gate whose `corpus` names a selected project. An empty list, a compiler/\n")) (ELit (LString "or stdlib/ path, and any path no project directory claims all FAIL OPEN\n")) (ELit (LString "to every project: this command never answers `nothing`.\n")) (ELit (LString "\n")) (ELit (LString "`gate budget` is #2180's governor: text-only, no build. Reds when (a) a\n")) (ELit (LString "schedulable gate has no cost baseline entry, (b) a gate's measured cost\n")) (ELit (LString "has eaten into the tolerance-adjusted timeout its declared `cost` class\n")) (ELit (LString "implies, (c) the projected pole/floor (the same number `gate balance\n")) (ELit (LString "--check` derives) exceeds S-4's budget, or (d) a baseline row names no\n")) (ELit (LString "gate the registry currently declares. Any violation may be accepted on\n")) (ELit (LString "purpose with a `Gate-Budget-Override: <token>` trailer on the commit\n")) (ELit (LString "message (there is no PR body in a merge_group run) — the failing gate\n")) (ELit (LString "prints the exact trailer to paste.\n")) (ELit (LString "\n")) (ELit (LString "  --commit-message <text>  budget: the commit message to scan for\n")) (ELit (LString "                     `Gate-Budget-Override:` trailers. Omit for none.\n")))))
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
(DData Public "GateResult" () ((variant "GateResult" (ConNamed (field "name" (TyCon "String")) (field "script" (TyCon "String")) (field "shell" (TyCon "String")) (field "exitCode" (TyCon "Int")) (field "timedOut" (TyCon "Bool")) (field "spawnError" (TyCon "String")) (field "seconds" (TyCon "Float")) (field "out" (TyCon "String")) (field "err" (TyCon "String")) (field "vacuous" (TyCon "Bool"))))) ())
(DData Private "RunEnv" () ((variant "RunEnv" (ConNamed (field "root" (TyCon "String")) (field "medaka" (TyCon "String")) (field "emitter" (TyCon "String")) (field "scratchRoot" (TyCon "String")) (field "timeoutOverride" (TyCon "Int"))))) ())
(DTypeSig false "scratchRootOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "scratchRootOf" (PWild) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "TMPDIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EBinOp "/=" (EApp (EVar "stripSlash") (EVar "t")) (ELit (LString "/tmp")))) (EVar "t") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_SCRATCH"))) (ELit (LString "/var/tmp/medaka-scratch")))))))
(DTypeSig false "stripSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripSlash" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "/")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeGateScratch" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeGateScratch" ((PVar "root")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "root"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/medaka_gate_XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "d") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "d"))))))))))
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
(DTypeSig false "gateArgs" (TyFun (TyCon "RunEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "gateArgs" ((PVar "env") (PVar "scratch") (PVar "secs") (PVar "cmd")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "medaka"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "emitter"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "TMPDIR=")) (EApp (EMethodRef "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_SCRATCH=")) (EApp (EMethodRef "display") (EVar "scratch"))) (ELit (LString ""))) (EBinOp "::" (ELit (LString "JOBS=1")) (EBinOp "::" (ELit (LString "timeout")) (EBinOp "::" (ELit (LString "-k")) (EBinOp "::" (ELit (LString "5s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "s"))) (EVar "cmd"))))))))))))
(DTypeSig false "gateInvocation" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gateInvocation" ((PVar "env") (PVar "g") (PVar "script")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "kind") (ELit (LString "native"))) (ETuple (ELit (LString "medaka test --native")) (EListLit (EFieldAccess (EVar "env") "medaka") (ELit (LString "test")) (ELit (LString "--native")) (ELit (LString "--json")) (EVar "script"))) (EBlock (DoLet false false (PVar "sh") (EApp (EVar "shellFor") (EVar "script"))) (DoExpr (ETuple (EVar "sh") (EListLit (EVar "sh") (EVar "script")))))))
(DTypeSig false "spawnFailure" (TyFun (TyCon "Gate") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyCon "GateResult"))))))
(DFunDef false "spawnFailure" ((PVar "g") (PVar "script") (PVar "msg") (PVar "dt")) (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (ELit (LString "sh"))) (fa "exitCode" (ELit (LInt 127))) (fa "timedOut" (EVar "False")) (fa "spawnError" (EVar "msg")) (fa "seconds" (EVar "dt")) (fa "out" (ELit (LString ""))) (fa "err" (ELit (LString ""))) (fa "vacuous" (EVar "False")))))
(DTypeSig false "nativeSummaryCounts" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nativeSummaryCounts" ((PVar "out")) (EMatch (EApp (EVar "parseJson") (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "j")) () (EApp (EVar "summaryPassFail") (EVar "j")))))
(DTypeSig false "summaryPassFail" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "summaryPassFail" ((PVar "j")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "summary"))) (EVar "j"))) (ELam ((PVar "summary")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "passed"))) (EVar "summary"))) (ELam ((PVar "pj")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "jsonGet") (ELit (LString "failed"))) (EVar "summary"))) (ELam ((PVar "fj")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "jsonAsInt") (EVar "pj"))) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "jsonAsInt") (EVar "fj"))) (ELam ((PVar "f")) (EApp (EVar "Some") (ETuple (EVar "p") (EVar "f"))))))))))))))
(DTypeSig false "nativeVacuous" (TyFun (TyCon "Gate") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "nativeVacuous" ((PVar "g") (PVar "code") (PVar "out")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "g") "kind") (ELit (LString "native"))) (EBinOp "==" (EVar "code") (ELit (LInt 0)))) (EMatch (EApp (EVar "nativeSummaryCounts") (EVar "out")) (arm (PCon "Some" (PTuple (PLit (LInt 0)) (PLit (LInt 0)))) () (EVar "True")) (arm PWild () (EVar "False")))))
(DTypeSig false "runOneGate" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "GateResult")))))
(DFunDef false "runOneGate" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "script"))) (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "gate script not found (registry `run` field): ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (ELit (LFloat 0.0))) (EBlock (DoLet false false (PTuple (PVar "sh") (PVar "cmd")) (EApp (EApp (EApp (EVar "gateInvocation") (EVar "env")) (EVar "g")) (EVar "script"))) (DoLet false false (PVar "secs") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))) (DoExpr (EMatch (EApp (EVar "makeGateScratch") (EFieldAccess (EVar "env") "scratchRoot")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not create a scratch dir: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LFloat 0.0)))) (arm (PCon "Ok" (PVar "scratch")) () (EBlock (DoLet false false (PVar "t0") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EApp (EApp (EApp (EApp (EVar "gateArgs") (EVar "env")) (EVar "scratch")) (EVar "secs")) (EVar "cmd")))) (DoLet false false (PVar "dt") (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "t0"))) (DoLet false false PWild (EApp (EVar "cleanupScratch") (EVar "scratch"))) (DoExpr (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "spawnFailure") (EVar "g")) (EVar "script")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not spawn the gate: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "dt"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (ERecordCreate "GateResult" ((fa "name" (EFieldAccess (EVar "g") "name")) (fa "script" (EVar "script")) (fa "shell" (EVar "sh")) (fa "exitCode" (EVar "code")) (fa "timedOut" (EBinOp "||" (EBinOp "==" (EVar "code") (ELit (LInt 124))) (EBinOp "==" (EVar "code") (ELit (LInt 137))))) (fa "spawnError" (ELit (LString ""))) (fa "seconds" (EVar "dt")) (fa "out" (EVar "out")) (fa "err" (EVar "errOut")) (fa "vacuous" (EApp (EApp (EApp (EVar "nativeVacuous") (EVar "g")) (EVar "code")) (EVar "out")))))))))))))))))
(DTypeSig false "gateOk" (TyFun (TyCon "GateResult") (TyCon "Bool")))
(DFunDef false "gateOk" ((PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0)))) (EApp (EVar "not") (EFieldAccess (EVar "r") "vacuous"))))
(DTypeSig false "msOf" (TyFun (TyCon "GateResult") (TyCon "Int")))
(DFunDef false "msOf" ((PVar "r")) (EApp (EVar "floatToInt") (EBinOp "*" (EFieldAccess (EVar "r") "seconds") (ELit (LFloat 1000.0)))))
(DTypeSig false "resultLine" (TyFun (TyCon "GateResult") (TyCon "String")))
(DFunDef false "resultLine" ((PVar "r")) (EIf (EBinOp "/=" (EFieldAccess (EVar "r") "spawnError") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "spawnError"))) (ELit (LString ")\n"))) (EIf (EFieldAccess (EVar "r") "timedOut") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TIMEOUT ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString " after "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EFieldAccess (EVar "r") "vacuous") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (vacuous: no doctests/props/`test \"…\"` ran, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "exitCode") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PASS  ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL  ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "  (exit "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "exitCode")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "msOf") (EVar "r"))))) (ELit (LString "ms)\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
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
(DFunDef false "resultJson" ((PVar "r")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "name"))) (ETuple (ELit (LString "script")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "script"))) (ETuple (ELit (LString "shell")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "shell"))) (ETuple (ELit (LString "exit")) (EApp (EVar "JInt") (EFieldAccess (EVar "r") "exitCode"))) (ETuple (ELit (LString "timedOut")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "timedOut"))) (ETuple (ELit (LString "ms")) (EApp (EVar "JInt") (EApp (EVar "msOf") (EVar "r")))) (ETuple (ELit (LString "seconds")) (EApp (EVar "JFloat") (EFieldAccess (EVar "r") "seconds"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EVar "gateOk") (EVar "r")))) (ETuple (ELit (LString "vacuous")) (EApp (EVar "JBool") (EFieldAccess (EVar "r") "vacuous"))) (ETuple (ELit (LString "spawnError")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "spawnError"))) (ETuple (ELit (LString "stdout")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "out"))) (ETuple (ELit (LString "stderr")) (EApp (EVar "JString") (EFieldAccess (EVar "r") "err"))))))
(DTypeSig true "runReportJson" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateResult")) (TyCon "String"))))
(DFunDef false "runReportJson" ((PVar "jobs") (PVar "rs")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jobs")) (EApp (EVar "JInt") (EVar "jobs"))) (ETuple (ELit (LString "parallel")) (EApp (EVar "JBool") (EVar "False"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JInt") (EApp (EVar "countOk") (EVar "rs")))) (ETuple (ELit (LString "failing")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "listLen") (EVar "rs")) (EApp (EVar "countOk") (EVar "rs"))))) (ETuple (ELit (LString "gates")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "resultJson")) (EVar "rs"))))))))
(DTypeSig false "dryLine" (TyFun (TyCon "RunEnv") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "dryLine" ((PVar "env") (PVar "g")) (EBlock (DoLet false false (PVar "script") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "env") "root"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (DoLet false false (PTuple (PVar "sh") (PVar "_cmd")) (EIf (EApp (EVar "fileExists") (EVar "script")) (EApp (EApp (EApp (EVar "gateInvocation") (EVar "env")) (EVar "g")) (EVar "script")) (ETuple (ELit (LString "sh")) (EListLit)))) (DoLet false false (PVar "orc") (EIf (EApp (EVar "isEmptyStrs") (EFieldAccess (EVar "g") "oracles")) (ELit (LString "-")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "g") "oracles")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "sh"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "script"))) (ELit (LString "\ttimeout="))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (EFieldAccess (EVar "env") "timeoutOverride")) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s\toracles="))) (EApp (EMethodRef "display") (EVar "orc"))) (ELit (LString "\n"))))))
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
(DTypeSig false "gitLsFilesSh" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "gitLsFilesSh" ((PVar "root") (PVar "args") (PVar "pattern")) (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "git"))) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "-C")) (EVar "root")) (EVar "args")) (EListLit (EVar "pattern")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "git ls-files failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EApp (EVar "filterList") (EVar "nonBlank")) (EApp (EVar "splitNl") (EVar "out")))))))
(DTypeSig false "candidatesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "candidatesFor" ((PVar "root") (PVar "pattern")) (EMatch (EApp (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")))) (EVar "pattern")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "tracked")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "tracked") (EVar "_s")))) (EApp (EApp (EApp (EVar "gitLsFilesSh") (EVar "root")) (EListLit (ELit (LString "ls-files")) (ELit (LString "-o")) (ELit (LString "--exclude-standard")))) (EVar "pattern"))))))
(DTypeSig false "directlyUnderTest" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "directlyUnderTest" ((PVar "p")) (EBinOp "==" (EApp (EVar "listLen") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "p"))) (ELit (LInt 2))))
(DTypeSig false "gateCandidates" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateCandidates" ((PVar "root")) (EMatch (EApp (EApp (EVar "candidatesFor") (EVar "root")) (ELit (LString "*.sh"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "shScripts")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "nativeTests")) (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "shScripts") (EApp (EApp (EVar "filterList") (EVar "directlyUnderTest")) (EVar "nativeTests")))))) (EApp (EApp (EVar "candidatesFor") (EVar "root")) (ELit (LString "test/*_test.mdk")))))))
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
(DTypeSig false "migrationClassOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "migrationClassOk" ((PVar "m")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "m") (ELit (LString "native-wrap"))) (EBinOp "==" (EVar "m") (ELit (LString "native-rewrite")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:trust-anchor")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:instrumentation")))) (EBinOp "==" (EVar "m") (ELit (LString "shell:external-harness")))) (EBinOp "==" (EVar "m") (ELit (LString "split-first")))) (EBinOp "==" (EVar "m") (ELit (LString "inverted-polarity")))) (EBinOp "==" (EVar "m") (ELit (LString "done")))))
(DTypeSig false "migrationClassNames" (TyCon "String"))
(DFunDef false "migrationClassNames" () (ELit (LString "native-wrap/native-rewrite/shell:trust-anchor/shell:instrumentation/shell:external-harness/split-first/inverted-polarity/done")))
(DTypeSig false "invalidMigrationViolations" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "invalidMigrationViolations" ((PList)) (EListLit))
(DFunDef false "invalidMigrationViolations" ((PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EVar "migrationClassOk") (EFieldAccess (EVar "g") "migration")) (EApp (EVar "invalidMigrationViolations") (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' is not one of "))) (EApp (EMethodRef "display") (EVar "migrationClassNames"))) (ELit (LString ""))) (EApp (EVar "invalidMigrationViolations") (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shellBecauseTag" (TyCon "String"))
(DFunDef false "shellBecauseTag" () (ELit (LString "shell-because:")))
(DTypeSig false "shellClassOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "shellClassOf" ((PVar "m")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "shell:"))) (EVar "m")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (ELit (LString "shell:")))) (EApp (EVar "stringLength") (EVar "m"))) (EVar "m")) (ELit (LString ""))))
(DTypeSig false "stripHash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripHash" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "s"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "#"))) (EVar "t")) (EApp (EVar "stripHash") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))) (EVar "t")))))
(DTypeSig false "becauseClassOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "becauseClassOf" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stripHash") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "shellBecauseTag")) (EVar "t")) (EApp (EVar "Some") (EApp (EVar "firstToken") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "shellBecauseTag"))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))))) (EVar "None")))))
(DTypeSig false "becauseClasses" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "becauseClasses" ((PList)) (EListLit))
(DFunDef false "becauseClasses" ((PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EVar "becauseClassOf") (EVar "l")) (arm (PCon "Some" (PVar "c")) () (EBinOp "::" (EVar "c") (EApp (EVar "becauseClasses") (EVar "ls")))) (arm (PCon "None") () (EApp (EVar "becauseClasses") (EVar "ls")))))
(DTypeSig false "shellBecauseErrors" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "shellBecauseErrors" ((PVar "root") (PVar "g")) (EBlock (DoLet false false (PVar "want") (EApp (EVar "shellClassOf") (EFieldAccess (EVar "g") "migration"))) (DoExpr (EIf (EBinOp "==" (EVar "want") (ELit (LString ""))) (EListLit) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "g") "run"))) (arm (PCon "Err" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but its run script cannot be read to confirm the reason: "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "becauseClasses") (EApp (EVar "splitNl") (EVar "src"))) (arm (PList) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString " carries no 'shell-because: "))) (EApp (EMethodRef "display") (EVar "want"))) (ELit (LString "' header line — a stays-shell exemption the script itself never states"))))) (arm (PCons (PVar "c") PWild) () (EIf (EBinOp "==" (EVar "c") (EVar "want")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ": migration '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "migration"))) (ELit (LString "' but "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString " states 'shell-because: "))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString "' — registry and script name different reason classes")))))))))))))
(DTypeSig false "shellBecauseViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "shellBecauseViolations" (PWild (PList)) (EListLit))
(DFunDef false "shellBecauseViolations" ((PVar "root") (PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EApp (EApp (EVar "shellBecauseErrors") (EVar "root")) (EVar "g")) (EApp (EApp (EVar "shellBecauseViolations") (EVar "root")) (EVar "gs"))))
(DTypeSig false "verifyClasses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "verifyClasses" ((PVar "root") (PVar "gates") (PVar "shs")) (EMatch (EApp (EVar "gateCandidates") (EVar "root")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "could not enumerate gate candidates: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "cands")) () (EBlock (DoLet false false (PVar "tools") (EApp (EVar "toolNames") (EVar "root"))) (DoLet false false (PVar "runs") (EApp (EVar "allRuns") (EVar "gates"))) (DoLet false false (PVar "known") (EApp (EVar "knownOracles") (EVar "root"))) (DoExpr (EApp (EVar "Ok") (EListLit (ETuple (ELit (LString "unenrolled gate scripts")) (EApp (EApp (EApp (EVar "unenrolledViolations") (EVar "tools")) (EVar "runs")) (EVar "cands"))) (ETuple (ELit (LString "missing run targets")) (EApp (EApp (EVar "runTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "missing oracle targets")) (EApp (EApp (EVar "oracleTargetViolations") (EVar "known")) (EVar "gates"))) (ETuple (ELit (LString "missing corpus targets")) (EApp (EApp (EVar "corpusTargetViolations") (EVar "root")) (EVar "gates"))) (ETuple (ELit (LString "unreachable entries")) (EApp (EApp (EVar "reachabilityViolations") (EVar "gates")) (EVar "gates"))) (ETuple (ELit (LString "duplicate entry names")) (EApp (EVar "duplicateNameViolations") (EVar "gates"))) (ETuple (ELit (LString "unsafe entry names")) (EApp (EApp (EVar "unsafeNameViolations") (EVar "gates")) (EVar "shs"))) (ETuple (ELit (LString "invalid cost class")) (EApp (EVar "invalidCostViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid tiers")) (EApp (EVar "invalidTiersViolations") (EVar "gates"))) (ETuple (ELit (LString "invalid migration class")) (EApp (EVar "invalidMigrationViolations") (EVar "gates"))) (ETuple (ELit (LString "unpaired shell-because")) (EApp (EApp (EVar "shellBecauseViolations") (EVar "root")) (EVar "gates"))))))))))
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
(DTypeSig false "runMatches" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "runMatches" ((PVar "path") (PVar "g")) (EIf (EBinOp "==" (EVar "path") (EFieldAccess (EVar "g") "run")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "run:")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "run"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "targetedReasons" (TyFun (TyCon "String") (TyFun (TyCon "Gate") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "targetedReasons" ((PVar "path") (PVar "g")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "sourceMatches") (EVar "path")) (EFieldAccess (EVar "g") "sources")) (EApp (EApp (EVar "corpusMatches") (EVar "path")) (EFieldAccess (EVar "g") "corpus"))) (EApp (EApp (EVar "runMatches") (EVar "path")) (EVar "g"))))
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
(DTypeSig false "balWrite" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "balWrite" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString " already balanced — no shard assignment changed\n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EVar "regPath")) (EVar "out")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: cannot write "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: rewrote the shard assignments in "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString "\n")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCheckResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "balCheckResult" ((PVar "regPath") (PVar "regSrc") (PVar "out") (PVar "head")) (EIf (EBinOp "==" (EVar "out") (EVar "regSrc")) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "medaka gate balance: "))) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString " already balanced\n")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EVar "head") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": the committed shard assignment is not the\n"))) (ELit (LString "one the balancer derives from test/gate_cost_baseline.json.  A `shard` field\n")) (ELit (LString "is DERIVED DATA (#2178): it is not hand-editable, and a hand edit that keeps\n")) (ELit (LString "ci.yml self-consistent is exactly what this check exists to catch.  First\n")) (ELit (LString "differing line:\n")) (EApp (EApp (EApp (EVar "ciDiffAt") (EApp (EVar "splitNl") (EVar "regSrc"))) (EApp (EVar "splitNl") (EVar "out"))) (ELit (LInt 1))) (ELit (LString "\nRun 'medaka gate balance' then 'make gen-ci', and commit both.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCmdBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "balCmdBody" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseBalArgs") (EVar "argv")) (ERecordCreate "BalArgs" ((fa "registry" (EVar "None")) (fa "baseline" (EVar "None")) (fa "check" (EVar "False"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PVar "a")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "regPath") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoLet false false (PVar "basePath") (EApp (EApp (EVar "balBaselinePath") (EFieldAccess (EVar "a") "baseline")) (EVar "root"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "regPath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "regSrc")) () (EMatch (EApp (EVar "readFile") (EVar "basePath")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: cannot read cost baseline ")) (EApp (EMethodRef "display") (EVar "basePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "baseSrc")) () (EMatch (EApp (EApp (EApp (EVar "balNewText") (EVar "regPath")) (EVar "regSrc")) (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "emit") (EApp (EVar "Err") (EVar "m")))) (arm (PCon "Ok" (PTuple (PVar "head") (PVar "out"))) () (EIf (EFieldAccess (EVar "a") "check") (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "balCheckResult") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))) (EApp (EApp (EApp (EApp (EVar "balWrite") (EVar "regPath")) (EVar "regSrc")) (EVar "out")) (EVar "head"))))))))))))))
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
