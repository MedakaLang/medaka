# META
source_lines=1988
stages=DESUGAR,MARK
# SOURCE
import tools.source_snapshot.{SourceRevision(..), SourceSnapshot(..)}
import tools.snapshot_syntax.{
  parseSnapshotSyntax, snapshotSyntaxResult, snapshotSyntaxSnapshot
}
import tools.syntax_queries.{symbolsFromRecovered, jPosition}
import tools.lsp_diagnostics.{diagnosticJsonOr}
import driver.parse_diag_adapter.{parseDiagnosticToDiag}
import frontend.recovery_result.{
  SourceExtent(..), InvalidReason(..), RecoveryStop(..),
  RecoveryCompleteness(..), invalidExtent, invalidReason, invalidRegions,
  recoveredDiagnostics, recoveredCompleteness
}
-- compiler/tools/mcp.mdk — the `medaka mcp` MCP (Model Context Protocol) server.
--
-- Foundation for the `medaka mcp` workstream (#246 / #247): a JSON-RPC 2.0
-- server over stdio that exposes the compiler to coding agents.  Everything a
-- later tool needs bolts onto the TOOL REGISTRY seam near the bottom of this file.
--
-- Framing (deliberately NOT lsp.mdk's Content-Length):
--   MCP stdio transport is **newline-delimited JSON** — exactly one JSON object
--   per line, no embedded newlines within a message.  We rely on json.stringify
--   emitting single-line output (it escapes '\n' → \n inside strings and uses
--   only `,`/`{}`/`[]` separators, so a value can never straddle two lines) and
--   read one line at a time with readLineOpt.
--
-- Channels:
--   stdout is the EXCLUSIVE protocol channel — every byte written there must be
--   a framed JSON-RPC message.  All logging goes to stderr via `logMcp`; a stray
--   stdout write corrupts the stream.
--
-- The json layer (parse/stringify/ctors) IS imported — it is already exported
-- and drags no new type surface.  A few tiny helpers (responseMsg, the
-- fieldOr/fieldStr/methodOf accessors, unit) are IMPORTED from lsp.mdk, which
-- exports them.  `errorMsg` is ORIGINAL to this file — LSP never emits a
-- JSON-RPC error object over its transport, so there is no lsp.mdk copy.

import json.{
  Json(..),
  jObject,
  jArray,
  stringify,
  parse,
  get,
  asString,
  asInt,
  asArray,
}
import string.{stripCR}
import support.source_index.{
  SourceIndex, indexSource, sourcePositionToOffset, offsetToUtf16Position,
  clampSourcePositionToOffset, sourceEndUtf16Position
}
import driver.diagnostics.{
  stdlibExportsReader,
  checkJsonSingle,
  checkJsonFile,
  cjAllToJson,
  cjFileEntry,
  parseErrDiag,
  diagIsError,
  Diag(..),
}
import tools.lsp.{
  typeAtPoint,
  typeAtPointsWithIndex,
  documentSymbols,
  definitionResult,
  definitionResultsWithIndex,
  referencesResult,
  emptyDocs,
  docsPut,
  uriOfPath,
  responseMsg,
  fieldOr,
  fieldStr,
  methodOf,
  unit,
}
import tools.lint_cmd.{quadToParseTriple, quadToSrc}
import frontend.ast.{Decl, Loc(..)}
import frontend.desugar.{desugar}
import frontend.parser.{
  Positions,
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import frontend.lexer.{tokenizeWithOffsetPairs}
import tools.fmt.{formatSourceChecked}
import tools.lint.{
  Finding,
  lintFileDiagTripleParsed,
  mergeCrossFileIntoTriples,
  runCrossFileRules,
  applySuppressionsMulti,
  applyFindingDeny,
  splitLintNames,
  buildStdlibIndexResult,
  StdlibIndexError(..),
  emptyStdlibIndex,
  stdlibIndexNeeded,
  StdlibIndex,
}
import tools.test_cmd.{runTestGradedReportParts, TestReportError(..)}
import driver.build_cmd.{lastPreludeStaleLine}
import driver.profile_select.{carryProjectProfile}
import types.target_profile.{selectedProfile}
import tools.doctest.{
  Example,
  ExResult(..),
  exResultJsonFields,
  RunResult,
  Engine(..),
  engineName,
  exampleInput,
  exampleLine,
  runPassed,
  runFailed,
  runErrors,
  runDetails,
}
import tools.prop_runner.{
  propResultName,
  propResultPassed,
  propResultDetail,
  propResultEngine,
  propResultSeed,
  propResultCases,
  propResultFailureKind,
}
import tools.eval_props.{propFailureKindJson}
import tools.test_pins_report.{
  GradedProp,
  gradedPropRaw,
  gradedPropPassed,
  gradedPropStatus,
  gradedPropRawStatus,
  gradedPropIssue,
  gradedPropPinDetail,
  knownRedCountProps,
}
import support.util.{joinWith}
import list.{zipWith}
import regex.{Regex, Match, mustCompile, findAll}

-- ── protocol / server identity ──────────────────────────────────────────────

-- Protocol revisions this server negotiates, oldest first.  This server is a
-- basic tools-only server (no resources/prompts/sampling), so its wire shape
-- has been protocol-compatible across every revision the SDK has shipped —
-- there's nothing here that changed shape between "2024-11-05" and
-- "2025-11-25". Listed explicitly (rather than derived) per the MCP spec's
-- negotiation rule: echo the client's requested version if it's in this set,
-- else fall back to the newest.
mcpSupportedVersions : List String
mcpSupportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

-- The newest supported revision — returned when the client's requested
-- version is missing or not in `mcpSupportedVersions`.
mcpLatestVersion : String
mcpLatestVersion = "2025-11-25"

-- Negotiate the protocol version for an `initialize` request: echo the
-- client's `params.protocolVersion` back if the server supports it, else
-- fall back to `mcpLatestVersion` (also covers a missing/non-string field).
negotiateVersion : Json -> String
negotiateVersion msg =
  let params = fieldOr "params" msg
  match fieldStr "protocolVersion" params
    Some v => if elem v mcpSupportedVersions then v else mcpLatestVersion
    None => mcpLatestVersion

-- ── JSON-RPC envelopes (responseMsg: lsp.mdk) ────────────────────────────────

-- A JSON-RPC error envelope: { jsonrpc, id, error: { code, message } }.
errorMsg : Json -> Int -> String -> Json
errorMsg idJson code message = jObject [
  ("jsonrpc", JString "2.0"),
  ("id", idJson),
  ("error", jObject [("code", JInt code), ("message", JString message)]),
]

-- ── field accessors (fieldOr, fieldStr, methodOf: lsp.mdk) ───────────────────

-- Integer field accessor (for tool args like `line`/`col`).  None when absent or
-- not a JInt — the caller reports the missing/invalid argument as an isError result.
fieldInt : String -> Json -> Option Int
fieldInt key j = match get key j
  Some v => asInt v
  None => None

-- ── stdio transport ──────────────────────────────────────────────────────────

-- Write one JSON-RPC message as a single newline-terminated line to stdout, then
-- flush (buffered stdout would otherwise strand the response).  `stringify` is
-- single-line, so this is exactly one MCP frame.
writeMessage : Json -> <IO> Unit
writeMessage j =
  let _ = putStr (stringify j)
  let _ = putStr "\n"
  flushStdout ()

-- All diagnostics go to stderr — stdout is protocol-only.
logMcp : String -> <IO> Unit
logMcp s = ePutStrLn (stringConcat ["[mcp] ", s])

-- ── opt-in call logging ──────────────────────────────────────────────────────
--
-- File logging is OPT-IN (unlike lsp.mdk's always-on debug log): when
-- MEDAKA_MCP_LOG is unset OR set to the empty string (an exported-but-empty
-- env var — treated identically to unset so it can't turn into a per-request
-- `appendFile ""` failure loop on stderr), `logMcpCall` is a no-op — one
-- getEnv check, no file I/O, no wall-clock read.  When set to a nonempty
-- path, each event is appended as one tab-separated line: "<wall-clock epoch
-- seconds>\t<method>\t<name>\t<args JSON>\n". Method-level events (no tool
-- name/args — everything but `tools/call`) call this with `name = ""` and
-- `args = ""`, but the two fields render DIFFERENTLY: `name` goes through
-- the `stringify (JString …)` wrap below, so the field is the literal
-- 2-character text `""`; `args` is spliced in RAW (it is already a
-- `stringify`d Json value, never re-wrapped), so an empty String there
-- contributes ZERO characters — the field is empty, not `""`. A
-- method-level line reads `<ts>\tinitialize\t""\t` (trailing tab, nothing
-- after it), not `<ts>\tinitialize\t""\t""`. `method` and `name` are passed
-- through `stringify (JString …)` (quoted + escaped — the same already-public
-- machinery `stringify` uses internally for any `JString`) rather than
-- interpolated raw: `name` is client-controlled (the `tools/call` "name"
-- argument), and an unescaped embedded '\n'/'\t' would split one record
-- across lines, breaking the one-record-per-line invariant this log format
-- promises. `args` is already a `stringify`d Json value, which is
-- single-line-safe on its own (see the file header on json.stringify's
-- escaping). stdout stays protocol-only (see header) — this writes ONLY to
-- the given file, via `appendFile`; a write failure falls back to stderr via
-- `logMcp` rather than crashing the server.
logMcpCall : String -> String -> String -> <IO> Unit
logMcpCall method name args = match getEnv "MEDAKA_MCP_LOG"
  None => unit
  Some "" => unit
  Some path =>
    let ts = floatToString (wallTimeSec ())
    let line = stringConcat [
      ts,
      "\t",
      stringify (JString method),
      "\t",
      stringify (JString name),
      "\t",
      args,
      "\n",
    ]
    match appendFile path line
      Ok _ => unit
      Err e => logMcp (stringConcat ["log write failed: ", e])

-- ── staleness signal (#846) ──────────────────────────────────────────────────
--
-- A subagent never starts its own MCP server — it inherits the orchestrator's,
-- which `exec`'d the orchestrator's `./medaka` binary at session launch (see
-- docs/ops/MCP.md §4).  For an agent editing `compiler/*.mdk`/`stdlib/core.mdk`
-- in its OWN worktree, every tool answer here is silently the WRONG compiler's
-- semantics.  The full fix (a per-worktree server) is a harness feature outside
-- this repo; the repo-controllable minimum is a STALENESS SIGNAL so a caller
-- can detect (not just be told in a doc to assume) that this server's binary
-- has drifted from the compiler source at its own MEDAKA_ROOT — the same
-- fingerprint check `checkSourceStaleness` already uses for the CLI startup
-- warning (medaka_cli.mdk's `sourceStalenessVerdict`), reused here rather than
-- reimplemented and threaded down as a closure (mcp.mdk cannot import
-- medaka_cli — it is the top of the graph and already imports tools.mcp).
--
-- Recomputed on every `tools/call` (~15ms: one `perl` pass + a hash tool over
-- `compiler/*.mdk`), not cached at server start, so it also catches the
-- documented "parent rebuilt mid-session, forgot to /mcp reconnect" trap, not
-- just launch-time staleness.  Cheap in TOKENS either way: adds nothing to a
-- fresh-binary response, and one short field on a stale one — never a verbose
-- per-response note.

-- Splice a compact `staleBinary` field onto an already-built tool result
-- (always a `JObject` — every mcpTools handler returns one via
-- `toolTextResult`) ONLY when the live compiler source has diverged from what
-- this binary was built from, and a `stalePreludeInterface` field when the
-- server found `stdlib/core.mdki` stale and checks `core.mdk` instead.
-- Fresh/unknown ⇒ `result` is returned UNCHANGED — zero added tokens in the
-- common case.
attachStaleness : (Unit -> <IO> Option String) -> Json -> <IO> Json
attachStaleness stalenessCheck result =
  let withBinary = match stalenessCheck ()
    None => result
    Some compilerDir =>
      jsonObjectAppend
        "staleBinary"
        (JString
          (stringConcat [
            "this server's binary predates the compiler source at ",
            compilerDir,
            " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).",
          ]))
        result
  -- The prelude interface's verdict was read once, at server start.
  match lastPreludeStaleLine ()
    None => withBinary
    Some line =>
      jsonObjectAppend "stalePreludeInterface" (JString line) withBinary

-- Append one (key, value) pair onto a `JObject`'s own Array-backed pairs,
-- preserving insertion order (json.mdk's own invariant).  A total fallback
-- for any non-JObject `j` (never actually hit — every handler's result is a
-- JObject — but this stays a total function rather than assuming it).
jsonObjectAppend : String -> Json -> Json -> Json
jsonObjectAppend key value (JObject pairs) =
  JObject (arrayFromList (jsonPairsToList pairs ++ [(key, value)]))
jsonObjectAppend _ _ other = other

jsonPairsToList : Array (String, Json) -> List (String, Json)
jsonPairsToList arr = jsonPairsToListGo arr 0 (arrayLength arr)

jsonPairsToListGo : Array (String, Json) -> Int -> Int -> List (String, Json)
jsonPairsToListGo arr i n
  | i >= n = []
  | otherwise = arrayGetUnsafe i arr :: jsonPairsToListGo arr (i + 1) n

-- ── handshake result values ──────────────────────────────────────────────────

-- `serverVersion` is medaka_cli.mdk's bare `medakaVersion` literal, threaded
-- down as a plain String (mcp.mdk cannot import medaka_cli — it is the top
-- of the dependency graph — so this is threaded the same way as
-- `stalenessCheck`, #846) rather than restating its own literal. Deliberately
-- NOT `medakaVersionString`'s per-build commit+date string — that value
-- changes on every commit and would make this protocol field permanently
-- unpinnable by a golden (issue #74 W8 follow-up).
initializeResultFor : String -> String -> Json
initializeResultFor protocolVersion serverVersion = jObject [
  ("protocolVersion", JString protocolVersion),
  ("capabilities", jObject [("tools", jObject [])]),
  (
    "serverInfo",
    jObject [("name", JString "medaka"), ("version", JString serverVersion)],
  ),
]

-- tools/list response: { tools: [ {name,description,inputSchema}, ... ] } — the
-- descriptor array is DERIVED from `mcpTools`, never hand-maintained.
toolsListResult : Json
toolsListResult = jObject [("tools", jArray (map toolDescriptor mcpTools))]

-- ═══ TOOL REGISTRY ═══════════════════════════════════════════════════════════
-- ONE record per tool — no more two-lists-kept-in-sync-by-a-comment.  Each
-- `McpTool` carries name, description, inputSchema, AND handler, and BOTH the
-- `tools/list` descriptor array (via `toolDescriptor`) and the `tools/call`
-- dispatch (via `callTool`/`lookupTool`) are DERIVED from `mcpTools` — so a
-- descriptor and its handler can never drift.
--
-- To add a tool (#249/#250/#251/#252/#255): write its handler, then add ONE
-- `McpTool` record below.  A handler is
--   runtimeSrc -> coreSrc -> stdlibDir -> args -> <IO> resultJson
-- (the prelude sources + stdlib dir are threaded from the driver so a handler can
-- run the compiler pipeline), and returns the tool result Json — typically
-- `{ content: [ { type: "text", text } ], isError }`.

data McpTool =
  McpTool String String Json (String -> String -> String -> Json -> <IO> Json)
--        name   desc   schema  handler(runtimeSrc coreSrc stdlibDir args)

-- Descriptions are DIRECTIVE (gopls/Serena convention), not just descriptive:
-- each says WHEN this tool beats grep/Bash, not only what it computes — the
-- model's default is to reach for Grep/Bash even with a working tool present
-- (anthropics/claude-code#32599; #847). Kept short on purpose — paid for in
-- every agent's context window on every session.
mcpTools : List McpTool
mcpTools = [
  McpTool
    "medaka_check"
    "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns structured JSON using zero-based UTF-16 positions (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`."
    medakaCheckSchema
    runCheckTool,
  McpTool
    "medaka_type_at"
    "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result."
    medakaTypeAtSchema
    runTypeAtTool,
  McpTool
    "medaka_symbols"
    "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. Incomplete source returns recoverable declarations; structuredContent reports completeness, invalid regions and diagnostics."
    medakaSymbolsSchema
    runSymbolsTool,
  McpTool
    "medaka_definition"
    "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result."
    medakaDefinitionSchema
    runDefinitionTool,
  McpTool
    "medaka_references"
    "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line` and UTF-16 `col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies."
    medakaReferencesSchema
    runReferencesTool,
  McpTool
    "medaka_fmt"
    "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)."
    medakaFmtSchema
    runFmtTool,
  McpTool
    "medaka_lint"
    "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`."
    medakaLintSchema
    runLintTool,
  McpTool "medaka_test" mcpTestDescription medakaTestSchema runTestTool,
]

-- The `tools/list` descriptor for one tool: { name, description, inputSchema }.
toolDescriptor : McpTool -> Json
toolDescriptor (McpTool name desc schema _) = jObject [
  ("name", JString name),
  ("description", JString desc),
  ("inputSchema", schema),
]

-- Dispatch a tools/call by tool name against `mcpTools`.  `None` ⇒ no such tool
-- (caller emits JSON-RPC -32601).  `Some result` ⇒ the tool's result Json.
callTool : String -> String -> String -> String -> Json -> <IO> Option Json
callTool runtimeSrc coreSrc stdlibDir name args =
  map
    ((McpTool _ _ _ handler) => handler runtimeSrc coreSrc stdlibDir args)
    (lookupTool name mcpTools)

lookupTool : String -> List McpTool -> Option McpTool
lookupTool _ [] = None
lookupTool name (t :: ts) = match t
  McpTool n _ _ _ => if n == name then Some t else lookupTool name ts

-- ── medaka_check tool ─────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text).
medakaCheckSchema : Json
medakaCheckSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          ("description", JString "Path to a .mdk file to check."),
        ],
      ),
      (
        "source",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString "Inline Medaka source to check (no file on disk).",
          ),
        ],
      ),
    ],
  ),
]

-- Stable synthetic filename for inline `source` checks — never a temp path, so a
-- transcript golden over a `source` call is path-free and portable.
syntheticSourceName : String
syntheticSourceName = "<source>"

-- Wrap a text payload as an MCP tool result: { content:[{type:text,text}], isError }.
toolTextResult : String -> Bool -> Json
toolTextResult text isErr = jObject (toolTextFields text isErr)

toolTextFields : String -> Bool -> List (String, Json)
toolTextFields text isErr = [
  (
    "content",
    jArray [jObject [("type", JString "text"), ("text", JString text)]],
  ),
  ("isError", JBool isErr),
]

-- An argument-validation failure, surfaced as an isError:true tool result (NOT a
-- crash, NOT a JSON-RPC error — the call was well-formed, its arguments weren't).
toolArgError : String -> Json
toolArgError msg = toolTextResult msg True

-- medaka_check handler: run the check pipeline over `file` XOR `source` and return
-- the {"files":[...]} JSON in a text content block.  isError=true iff any
-- diagnostic is a hard error.  Inline `source` is checked WITHOUT touching disk
-- (checkJsonSingle), its diagnostics carrying the stable synthetic filename
-- "<source>".  `file` is readFile'd FIRST (#333 — mirrors medaka_symbols/
-- medaka_type_at/medaka_definition) so a nonexistent/unreadable path returns a
-- clean "cannot read file" toolArgError instead of falling into checkJsonFile's
-- import loader, which otherwise misreports it as an unknown-module R-MODULE-LOAD
-- diagnostic (checkJsonFile reads the path itself via readFileSafe, which swallows
-- the error as "" — this guard only validates readability; the content it reads is
-- discarded and checkJsonFile re-reads `path` for the real run, full import
-- resolution).
runCheckTool : String -> String -> String -> Json -> <IO> Json
runCheckTool runtimeSrc coreSrc stdlibDir args = match (
  fieldStr "file" args,
  fieldStr "source" args,
)
  (Some _, Some _) =>
    toolArgError
      "medaka_check: provide exactly one of 'file' or 'source', not both"
  (None, None) =>
    toolArgError
      "medaka_check: missing argument — provide exactly one of 'file' or 'source'"
  (Some path, None) => match readFile path
    Err e =>
      toolArgError
        (stringConcat ["medaka_check: cannot read file '", path, "': ", e])
    Ok _ => match carryProjectProfile None path
      Err m => toolArgError ("medaka_check: error: " ++ m)
      Ok _ =>
        let (json, hasErr) =
          checkJsonFile False runtimeSrc coreSrc path stdlibDir
        toolTextResult json hasErr
  (None, Some src) =>
    -- Inline source belongs to no project, and this server has analyzed other
    -- projects' files before it.
    selectedProfile := None
    let (json, hasErr) =
      checkJsonSingle
        (stdlibExportsReader stdlibDir)
        ""
        False
        runtimeSrc
        coreSrc
        syntheticSourceName
        src
    toolTextResult json hasErr

-- ── symbol-name addressing (#849) ───────────────────────────────────────────
-- `medaka_type_at`/`medaka_definition` accept an alternative to a numeric
-- `col`: a `symbol` name to locate on `line`, so a caller that cannot
-- reliably count characters names the identifier instead of computing an
-- offset.  Resolution is a plain scan over the QUERIED LINE'S OWN TEXT,
-- entirely self-contained here — deliberately NOT routed through
-- tools.refindex/tools.lsp (both under an active lock for the #254 rename
-- arc; see #849's own instructions).  The same line scan also powers the
-- miss hint below: on ANY empty result — an off-identifier `col`, or a
-- `symbol` absent from the line — the response names the identifiers that
-- ARE on that line, so a wrong guess is self-correcting instead of the bare
-- empty result #849 reports as indistinguishable from "there's nothing
-- here".

-- The `symbol` argument, normalized: an empty string reads as "not
-- provided" (same as absent), never as "search for the empty string" — this
-- codebase has a documented trap where an empty-but-present JSON value
-- silently behaves as "set", so both states must collapse to the same
-- fallback (drop to 'col', or the "missing argument" error if neither was
-- given).
fieldSymbol : Json -> Option String
fieldSymbol args = match fieldStr "symbol" args
  Some "" => None
  other => other

-- The raw text of a zero-based line, excluding its line terminator.
lineTextAt : String -> Int -> Option String
lineTextAt src line = lineTextAtIndexed (indexSource src) src line

lineTextAtIndexed : SourceIndex -> String -> Int -> Option String
lineTextAtIndexed index src line =
  map
    (start =>
      stringSlice
        start
        (lineTextEnd (stringToChars src) (stringLength src) start)
        src)
    (sourcePositionToOffset index (line + 1) 0)

lineTextEnd : Array Char -> Int -> Int -> Int
lineTextEnd arr len i
  | i >= len = len
  | arrayGetUnsafe i arr == '\n' || arrayGetUnsafe i arr == '\r' = i
  | otherwise = lineTextEnd arr len (i + 1)

-- Every identifier token on `text` (the WIDE class `support.char.isIdentChar`
-- runs — alnum, `_`, `'`), as (name, 0-based column) pairs in left-to-right
-- order.
identTokenRe : Regex
identTokenRe = mustCompile "[A-Za-z0-9_']+"

identifiersInLine : String -> List (String, Int)
identifiersInLine text =
  map (identPair (indexSource text)) (findAll identTokenRe text)

identPair : SourceIndex -> Match -> (String, Int)
-- Identifier matches contain no newline; both regex and index use this exact text.
identPair index m = match offsetToUtf16Position index m.start
  Some (_, col) => (m.text, col)
  None => panic "identifier regex returned a non-source boundary"

-- Columns where `symbol` appears as a WHOLE identifier token on `text`
-- (exact match, not substring — "x" does not match "xs").
symbolColsInSource : SourceIndex -> Int -> String -> String -> List Int
symbolColsInSource index line text symbol =
  match sourcePositionToOffset index (line + 1) 0
    None => []
    Some start =>
      symbolColsGo
        (map (identPairAt index start) (findAll identTokenRe text))
        symbol

identPairAt : SourceIndex -> Int -> Match -> (String, Int)
identPairAt index start m = match offsetToUtf16Position index (start + m.start)
  Some (_, col) => (m.text, col)
  None => panic "identifier regex returned a non-source boundary"

symbolColsGo : List (String, Int) -> String -> List Int
symbolColsGo [] _ = []
symbolColsGo ((name, col) :: rest) symbol
  | name == symbol = col :: symbolColsGo rest symbol
  | otherwise = symbolColsGo rest symbol

-- "name (col N), name (col N), …" for a miss-hint message; "(none)" for an
-- identifier-free line.
describeIdentifiers : List (String, Int) -> String
describeIdentifiers [] = "(none)"
describeIdentifiers ids = joinWith ", " (map identColDesc ids)

identColDesc : (String, Int) -> String
identColDesc pair =
  stringConcat [fst pair, " (col ", intToString (snd pair), ")"]

-- ── medaka_type_at tool ───────────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`, the 0-based LSP-style line, plus
-- EXACTLY ONE of `col` (0-based column) or `symbol` (a name to locate on
-- that line — #849).  `file`/`line` are required; `col`/`symbol` are each
-- optional in the schema (JSON Schema can't express "exactly one of"), so
-- the handler enforces that.
medakaTypeAtSchema : Json
medakaTypeAtSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          ("description", JString "Path to the .mdk file to query."),
        ],
      ),
      (
        "line",
        jObject [
          ("type", JString "integer"),
          (
            "description",
            JString "0-based line of the position (LSP-style, first line is 0).",
          ),
        ],
      ),
      (
        "col",
        jObject [
          ("type", JString "integer"),
          (
            "description",
            JString
              "0-based UTF-16 column. Alternative to 'symbol' — provide exactly one.",
          ),
        ],
      ),
      (
        "symbol",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.",
          ),
        ],
      ),
    ],
  ),
  ("required", jArray [JString "file", JString "line"]),
]

-- medaka_type_at handler: read `file` from disk and infer the type at `line`
-- plus either `col` (UTF-16) or `symbol` (#849 — resolved to a column by
-- searching the line's own text, so a caller never has to count characters).
-- `symbol` matching MORE than one identifier on the line reports each match
-- rather than silently picking one.  Any miss — off-identifier `col`, or a
-- `symbol` absent from the line — is a CLEAN, ACTIONABLE result
-- (isError=false, never a crash) naming the identifiers actually on that
-- line, so a wrong guess is self-correcting instead of the bare "no symbol"
-- text this used to return with no further recourse.  A missing file or bad
-- arguments ⇒ an isError result (the arguments were malformed, not the
-- call).
runTypeAtTool : String -> String -> String -> Json -> <IO> Json
runTypeAtTool runtimeSrc coreSrc _stdlibDir args = match (
  fieldStr "file" args,
  fieldInt "line" args,
)
  (Some path, Some line) => match readFile path
    Err e =>
      toolArgError
        (stringConcat ["medaka_type_at: cannot read file '", path, "': ", e])
    Ok src => match (fieldInt "col" args, fieldSymbol args)
      (Some _, Some _) =>
        toolArgError
          "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both"
      (None, None) =>
        toolArgError
          "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)"
      (Some col, None) => typeAtOneCol runtimeSrc coreSrc path src line col
      (None, Some symbol) =>
        let index = indexSource src
        match lineTextAtIndexed index src line
          None =>
            toolTextResult
              (stringConcat [
                "medaka_type_at: line ",
                intToString line,
                " does not exist in '",
                path,
                "'",
              ])
              False
          Some lineText => match symbolColsInSource index line lineText symbol
            [] =>
              toolTextResult
                (stringConcat [
                  "no identifier named '",
                  symbol,
                  "' on line ",
                  intToString line,
                  " of '",
                  path,
                  "' — identifiers on this line: ",
                  describeIdentifiers (identifiersInLine lineText),
                ])
                False
            [col] => typeAtOneCol runtimeSrc coreSrc path src line col
            cols =>
              typeAtManyCols index runtimeSrc coreSrc path src line symbol cols
  _ =>
    toolArgError
      "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"

-- Resolve one (line, col) via the existing stateless hover harness
-- (tools.lsp.typeAtPoint).  A miss is enriched with the identifiers actually
-- on that line (#849) — applies to BOTH addressing modes, since a col-mode
-- miss is exactly the ambiguity #849 reports.
typeAtOneCol : String -> String -> String -> String -> Int -> Int -> <IO> Json
typeAtOneCol runtimeSrc coreSrc path src line col =
  match typeAtPoint runtimeSrc coreSrc path src line col
    Some ty => toolTextResult ty False
    None => toolTextResult (typeAtMissNote src line col) False

typeAtMissNote : String -> Int -> Int -> String
typeAtMissNote src line col = match lineTextAt src line
  None => stringConcat [
    "no symbol at line ",
    intToString line,
    " col ",
    intToString col,
  ]
  Some lineText => stringConcat [
    "no symbol at line ",
    intToString line,
    " col ",
    intToString col,
    " — identifiers on this line: ",
    describeIdentifiers (identifiersInLine lineText),
  ]

-- `symbol` matched more than one identifier on `line` — report EACH
-- resolved type rather than silently picking the first (#849's "or all
-- matches if ambiguous, returning each").
typeAtManyCols : SourceIndex ->
  String ->
  String ->
  String ->
  String ->
  Int ->
  String ->
  List Int ->
  <IO> Json
typeAtManyCols index runtimeSrc coreSrc path src line symbol cols =
  let header = stringConcat
    [
      "'",
      symbol,
      "' is ambiguous on line ",
      intToString line,
      " — ",
      intToString (length cols),
      " matches:",
    ]
  -- Every match is answered from one analysis of the file.
  let answers =
    typeAtPointsWithIndex index runtimeSrc coreSrc path src line cols
  let bodies = zipWith typeAtColLine cols answers
  toolTextResult (joinWith "\n" (header :: bodies)) False

typeAtColLine : Int -> Option String -> String
typeAtColLine col (Some ty) = stringConcat ["  col ", intToString col, ": ", ty]
typeAtColLine col None = stringConcat ["  col ", intToString col, ": no symbol"]

-- ── medaka_symbols tool ───────────────────────────────────────────────────────

-- inputSchema: `file` (path), required.
medakaSymbolsSchema : Json
medakaSymbolsSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString "Path to the .mdk file to list symbols for.",
          ),
        ],
      ),
    ],
  ),
  ("required", jArray [JString "file"]),
]

reasonName : InvalidReason -> String
reasonName InvalidDeclaration = "invalidDeclaration"
reasonName TerminalLexError = "terminalLexError"
reasonName UnclosedDelimiter = "unclosedDelimiter"
reasonName MismatchedDelimiter = "mismatchedDelimiter"
reasonName UntrustedBoundary = "untrustedBoundary"
reasonName RecoveryBudget = "recoveryBudget"

stopName : RecoveryStop -> String
stopName ReachedEnd = "reachedEnd"
stopName StoppedLexically = "stoppedLexically"
stopName StoppedDelimiter = "stoppedDelimiter"
stopName StoppedBoundary = "stoppedBoundary"
stopName ExhaustedBudget = "exhaustedBudget"

regionPosition : SourceIndex -> Int -> Json
regionPosition index off = match offsetToUtf16Position index off
  Some (line, col) => jPosition line col
  None => JNull

symbolsResult : String -> String -> Json
symbolsResult path src =
  let revision = SourceRevision (uriOfPath path) None 0 src
  let syntax = parseSnapshotSyntax revision
  let result = snapshotSyntaxResult syntax
  let (completeness, stop) = match recoveredCompleteness result
    Complete => ("complete", JNull)
    Partial why => ("partial", JString (stopName why))
  let (regions, diagnostics) = match snapshotSyntaxSnapshot syntax
    None =>
      let (line, col) = sourceEndUtf16Position src
      (
        [
          jObject [
            ("start", jObject [("line", JInt 0), ("character", JInt 0)]),
            ("end", jObject [("line", JInt line), ("character", JInt col)]),
            ("reason", JString "recoveryBudget"),
          ],
        ],
        [],
      )
    Some (SourceSnapshot _ _ _ _ index) => (
      map
        (region => match invalidExtent region
          SourceExtent start end => jObject [
            ("start", regionPosition index start),
            ("end", regionPosition index end),
            ("reason", JString (reasonName (invalidReason region))),
          ])
        (invalidRegions result),
      map
        (d => diagnosticJsonOr index JNull (parseDiagnosticToDiag path d))
        (recoveredDiagnostics result),
    )
  let metadata = jObject [
    (
      "origin",
      jObject [
        ("uri", JString (uriOfPath path)),
        ("version", JNull),
        ("generation", JInt 0),
      ],
    ),
    ("completeness", JString completeness),
    ("stop", stop),
    ("invalidRegions", jArray regions),
    ("diagnostics", jArray diagnostics),
  ]
  match symbolsFromRecovered revision syntax
    Err _ => toolArgError "medaka_symbols: snapshot mismatch"
    Ok symbols =>
      jObject
        (toolTextFields (stringify (jArray symbols)) False
          ++ [("structuredContent", metadata)])

runSymbolsTool : String -> String -> String -> Json -> <IO> Json
runSymbolsTool _runtimeSrc _coreSrc _stdlibDir args = match fieldStr "file" args
  None =>
    toolArgError
      "medaka_symbols: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e =>
      toolArgError
        (stringConcat ["medaka_symbols: cannot read file '", path, "': ", e])
    Ok src => symbolsResult path src

-- ── medaka_definition tool ───────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`, the 0-based LSP-style line, plus
-- EXACTLY ONE of `col` (0-based column) or `symbol` (a name to locate on
-- that line — #849).  `file`/`line` are required; `col`/`symbol` are each
-- optional in the schema (JSON Schema can't express "exactly one of"), so
-- the handler enforces that.
-- Same schema as `medakaTypeAtSchema` (#602: an in-file structural duplicate —
-- both tools take the identical file/line + col-or-symbol input contract).
medakaDefinitionSchema : Json
medakaDefinitionSchema = medakaTypeAtSchema

-- Synthesize a `{ position: { line, character } }` params Json — the shape
-- `tools.lsp.definitionResult` expects (it reads position.line/character via
-- positionLine/positionChar, the same accessors the real LSP request handler
-- uses).
positionParams : Int -> Int -> Json
positionParams line col =
  jObject [("position", jObject [("line", JInt line), ("character", JInt col)])]

-- One (line, col) resolved via the existing stateless, INTRA-FILE-ONLY
-- harness (tools.lsp.definitionResult) — a HIT is returned EXACTLY as
-- before, the raw `[{uri,range}]` array, unchanged.  A miss (`definitionResult`
-- answers `JNull` — off any identifier, or a name not defined in THIS file,
-- e.g. an imported name; definition is intra-file only, see #254 for
-- cross-file) is enriched with the identifiers actually on that line (#849)
-- rather than left as a bare `null`, indistinguishable from "there's nothing
-- here".  Applies to BOTH addressing modes — a col-mode miss is exactly the
-- ambiguity #849 reports.
definitionAtCol : String -> String -> Int -> Int -> Json
definitionAtCol path src line col =
  match definitionResult path src (positionParams line col)
    JNull => definitionMissNote line (Some col) src
    hit => hit

-- Shared miss-note shape for medaka_definition: an empty `matches`, a short
-- `note`, and (when the line exists) the identifiers actually on it.
definitionMissNote : Int -> Option Int -> String -> Json
definitionMissNote line maybeCol src =
  let posDesc = match maybeCol
    Some col =>
      stringConcat ["line ", intToString line, " col ", intToString col]
    None => stringConcat ["line ", intToString line]
  match lineTextAt src line
    None => jObject [
      ("matches", jArray []),
      ("note", JString (stringConcat ["no symbol at ", posDesc])),
    ]
    Some lineText => jObject [
      ("matches", jArray []),
      ("note", JString (stringConcat ["no symbol at ", posDesc])),
      (
        "identifiersOnLine",
        jArray (map identPairJson (identifiersInLine lineText)),
      ),
    ]

identPairJson : (String, Int) -> Json
identPairJson pair =
  jObject [("name", JString (fst pair)), ("col", JInt (snd pair))]

-- `symbol` matched more than one identifier on `line` — resolve EACH
-- (#849's "or all matches if ambiguous, returning each") rather than
-- silently picking the first.
definitionManyCols : SourceIndex ->
  String ->
  String ->
  Int ->
  String ->
  List Int ->
  Json
definitionManyCols index path src line symbol cols = jObject [
  ("ambiguous", JBool True),
  ("symbol", JString symbol),
  (
    "matches",
    jArray
      (zipWith
        definitionOneMatch
        cols
        (definitionResultsWithIndex index path src line cols)),
  ),
]

definitionOneMatch : Int -> Json -> Json
definitionOneMatch col result = jObject [
  ("col", JInt col),
  ("result", result),
]

-- medaka_definition handler: read `file` from disk and resolve the
-- identifier at `line` plus either `col` (UTF-16) or `symbol` (#849 —
-- resolved to a column by searching the line's own text).  `uri` is passed
-- as the caller's own `file` string, UNCHANGED (no `uriOfPath`/`file://`
-- wrapping) — a relative request path stays relative in the echoed result,
-- so a transcript golden over it is path-stable.  A missing file or bad
-- arguments ⇒ an isError result (the arguments were malformed, not the
-- call); every other outcome (hit, miss, ambiguous, out-of-range line) is a
-- CLEAN, ACTIONABLE result, never a crash.
runDefinitionTool : String -> String -> String -> Json -> <IO> Json
runDefinitionTool _runtimeSrc _coreSrc _stdlibDir args = match (
  fieldStr "file" args,
  fieldInt "line" args,
)
  (Some path, Some line) => match readFile path
    Err e =>
      toolArgError
        (stringConcat ["medaka_definition: cannot read file '", path, "': ", e])
    Ok src => match (fieldInt "col" args, fieldSymbol args)
      (Some _, Some _) =>
        toolArgError
          "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both"
      (None, None) =>
        toolArgError
          "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)"
      (Some col, None) =>
        toolTextResult (stringify (definitionAtCol path src line col)) False
      (None, Some symbol) =>
        let index = indexSource src
        match lineTextAtIndexed index src line
          None =>
            toolTextResult
              (stringify
                (jObject [
                  ("matches", jArray []),
                  (
                    "note",
                    JString
                      (stringConcat [
                        "line ",
                        intToString line,
                        " does not exist in '",
                        path,
                        "'",
                      ]),
                  ),
                ]))
              False
          Some lineText => match symbolColsInSource index line lineText symbol
            [] =>
              toolTextResult
                (stringify
                  (jObject [
                    ("matches", jArray []),
                    (
                      "note",
                      JString
                        (stringConcat [
                          "no identifier named '",
                          symbol,
                          "' on line ",
                          intToString line,
                          " of '",
                          path,
                          "'",
                        ]),
                    ),
                    (
                      "identifiersOnLine",
                      jArray (map identPairJson (identifiersInLine lineText)),
                    ),
                  ]))
                False
            [col] =>
              toolTextResult
                (stringify (definitionAtCol path src line col))
                False
            cols =>
              toolTextResult
                (stringify (definitionManyCols index path src line symbol cols))
                False
  _ =>
    toolArgError
      "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"

-- ── medaka_references tool ───────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`/`col`, the 0-based LSP-style
-- position; optional `includeDeclaration` (boolean, default true, F6).
medakaReferencesSchema : Json
medakaReferencesSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          ("description", JString "Path to the .mdk file to query."),
        ],
      ),
      (
        "line",
        jObject [
          ("type", JString "integer"),
          (
            "description",
            JString "0-based line of the position (LSP-style, first line is 0).",
          ),
        ],
      ),
      (
        "col",
        jObject [
          ("type", JString "integer"),
          (
            "description",
            JString "0-based UTF-16 column of the position (first column is 0).",
          ),
        ],
      ),
      (
        "includeDeclaration",
        jObject [
          ("type", JString "boolean"),
          (
            "description",
            JString
              "Include the symbol's own declaration site in the result. Default true.",
          ),
        ],
      ),
    ],
  ),
  ("required", jArray [JString "file", JString "line", JString "col"]),
]

-- Synthesize a `{ position, context: { includeDeclaration } }` params Json —
-- the shape `tools.lsp.referencesResult` expects (`positionLine`/
-- `positionChar` plus `includeDeclarationOf`'s `context.includeDeclaration`).
referencesParams : Int -> Int -> Bool -> Json
referencesParams line col includeDecl = jObject [
  ("position", jObject [("line", JInt line), ("character", JInt col)]),
  ("context", jObject [("includeDeclaration", JBool includeDecl)]),
]

-- medaka_references handler: read `file` from disk and resolve the identifier
-- at (line, col) to every use across the WHOLE PROJECT (cross-file, unlike
-- medaka_definition — see #254), via the stateless harness
-- `tools.lsp.referencesResult`. The buffer is seeded into a single-entry
-- `Docs` table under its own uri (mirrors `typeAtPoint`'s own construction)
-- so the exact requested content is used for THIS file; every other project
-- file is read from disk through the loader's own read-then-disk fallback.
-- Read-only, intra-project (F1): a stdlib/prelude symbol's uses within the
-- project are returned, but the index never walks into stdlib bodies, and it
-- never writes anything. Off any identifier, or a click that resolves to
-- nothing indexed, returns an empty `[]` result — never a crash, never a
-- wrong hit.
runReferencesTool : String -> String -> String -> Json -> <IO> Json
runReferencesTool runtimeSrc coreSrc _stdlibDir args = match (
  fieldStr "file" args,
  fieldInt "line" args,
  fieldInt "col" args,
)
  (Some path, Some line, Some col) => match readFile path
    Err e =>
      toolArgError
        (stringConcat ["medaka_references: cannot read file '", path, "': ", e])
    Ok src =>
      let includeDecl = fieldBoolOr "includeDeclaration" True args
      let uri = uriOfPath path
      let docs = docsPut uri src emptyDocs
      let result =
        referencesResult
          runtimeSrc
          coreSrc
          uri
          src
          (referencesParams line col includeDecl)
          docs
      toolTextResult (stringify result) False
  _ =>
    toolArgError
      "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"

-- ── medaka_fmt tool ───────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text); optional
-- `check` (boolean, default false — see medakaFmtSchema's own "check" doc).
medakaFmtSchema : Json
medakaFmtSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply.",
          ),
        ],
      ),
      (
        "source",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString "Inline Medaka source to format (no file on disk).",
          ),
        ],
      ),
      (
        "check",
        jObject [
          ("type", JString "boolean"),
          (
            "description",
            JString
              "If true, report clean/dirty instead of returning the formatted text (default false).",
          ),
        ],
      ),
    ],
  ),
]

-- Boolean field accessor with a default: absent key or a non-boolean JSON
-- value both fall back to `dflt` (an argument-shape error, not a crash — the
-- caller reports it, same policy as fieldStr/fieldInt).
fieldBoolOr : String -> Bool -> Json -> Bool
fieldBoolOr key dflt j = match get key j
  Some (JBool b) => b
  _ => dflt

-- Format (or format-check) already-resolved source text.  The source is lexed
-- once and `formatSourceChecked` both checks it and formats it, so an
-- unparseable source returns the located parse diagnostic as an explicit isError
-- result (never a silent no-op, and never the panicking `formatSource` path).
fmtResult : Bool -> String -> Json
fmtResult check src = match tokenizeWithOffsetPairs src
  (toks, pairs) => match formatSourceChecked src toks pairs
    Err e =>
      let index = indexSource src
      let offset =
        clampSourcePositionToOffset index (parseErrorLine e) (parseErrorCol e)
      let loc = match offsetToUtf16Position index offset
        Some (line, col) =>
          stringConcat ["line ", intToString line, ", col ", intToString col]
        None => "unknown position"
      toolArgError
        (stringConcat [
          "medaka_fmt: source does not parse (",
          loc,
          "): ",
          parseErrorMessage e,
        ])
    Ok formatted =>
      if check then
        toolTextResult
          (stringify (jObject [("clean", JBool (formatted == src))]))
          False
      else
        toolTextResult formatted False

-- medaka_fmt handler: format `file` XOR `source` and return either the
-- formatted text (default) or a `{"clean": bool}` verdict (`check: true`).
-- NEVER writes to disk: `file` is only ever passed to `readFile`, never opened
-- for writing, and no branch here shells out to `fmt --write` — the tree's
-- worst known source-destroyer (#51: a float literal ≥1e15 round-trips to a
-- form the lexer can't read back). The formatted text is returned for the
-- CALLER to apply, exactly as the issue's guardrail requires.
runFmtTool : String -> String -> String -> Json -> <IO> Json
runFmtTool _runtimeSrc _coreSrc _stdlibDir args =
  let check = fieldBoolOr "check" False args
  match (fieldStr "file" args, fieldStr "source" args)
    (Some _, Some _) =>
      toolArgError
        "medaka_fmt: provide exactly one of 'file' or 'source', not both"
    (None, None) =>
      toolArgError
        "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'"
    (Some path, None) => match readFile path
      Err e =>
        toolArgError
          (stringConcat ["medaka_fmt: cannot read file '", path, "': ", e])
      Ok src => fmtResult check src
    (None, Some src) => fmtResult check src

-- ── medaka_lint tool ──────────────────────────────────────────────────────────

-- inputSchema: `paths` (array of file path strings, required) plus the
-- lint CLI's rule-name-list flags as comma-separated strings — `deny`/`only`/
-- `disable` (mirrors --deny/--only/--disable). Report-only (#249): no `--fix`
-- equivalent — a suggesting rule must prove its fix compiles (TOOLING.md /
-- #56) and report-only sidesteps that for v1.
medakaLintSchema : Json
medakaLintSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "paths",
        jObject [
          ("type", JString "array"),
          ("items", jObject [("type", JString "string")]),
          ("description", JString "Paths to .mdk files to lint."),
        ],
      ),
      (
        "deny",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Comma-separated rule names to promote to error severity (mirrors --deny).",
          ),
        ],
      ),
      (
        "only",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only).",
          ),
        ],
      ),
      (
        "disable",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Comma-separated rule names to suppress (mirrors --disable).",
          ),
        ],
      ),
    ],
  ),
  ("required", jArray [JString "paths"]),
]

-- Convert a JArray's backing Array into a List. arrayLength/arrayGetUnsafe are
-- core builtins (no stdlib import needed) — mirrors eval.mdk's arrayToListG,
-- duplicated here rather than pulling in the `array` stdlib module (a new
-- import surface) for this one conversion.
jsonArrToList : Array Json -> List Json
jsonArrToList arr = jsonArrToListGo arr 0 (arrayLength arr)

jsonArrToListGo : Array Json -> Int -> Int -> List Json
jsonArrToListGo arr i n
  | i >= n = []
  | otherwise = arrayGetUnsafe i arr :: jsonArrToListGo arr (i + 1) n

-- `paths` -> `List String`, or `None` if missing, not a JSON array, or
-- containing any non-string element — a malformed `paths` is reported as an
-- argument error, never silently dropped/skipped element-by-element.
pathsArg : Json -> Option (List String)
pathsArg args = match get "paths" args
  None => None
  Some v => match asArray v
    None => None
    Some arr => allJsonStrings (jsonArrToList arr)

allJsonStrings : List Json -> Option (List String)
allJsonStrings [] = Some []
allJsonStrings (j :: rest) = match (asString j, allJsonStrings rest)
  (Some s, Some ss) => Some (s :: ss)
  _ => None

-- Optional comma-separated rule-name-list argument -> `List String`. Absent or
-- empty-string -> `[]` (no filtering); reuses `tools.lint.splitLintNames` (the
-- exact splitter `parseLintFlagList` uses for the CLI's `--deny=`/`--only=`/
-- `--disable=` flags) so the CLI and MCP surfaces can never parse "a,b,c"
-- differently.
lintNameListArg : String -> Json -> List String
lintNameListArg key args = match fieldStr key args
  None => []
  Some "" => []
  Some s => splitLintNames s

-- Sequence `lintFileDiagTripleParsed` over every target path, in order (same
-- explicit-recursion idiom `medaka_cli.mdk`'s `lintFilesToDiagTriples` uses —
-- `map` over an effectful function is not how this codebase sequences an
-- `<IO>` list traversal).  Carries the parse (`Positions`, `List Decl`) along
-- so the cross-file tier can reuse it — the SAME no-second-parse discipline
-- `lint_cmd.mdk`'s `lintFilesToDiagQuads` uses.
--
-- `idx` is the stdlib reference index, built ONCE by the caller and threaded:
-- it is the same value for every path in the request, and rebuilding it per
-- path would re-parse the whole stdlib once per target file.  Exported so
-- `compiler/tools/lint_test.mdk`'s renderer-parity property can call the SAME
-- function `runLintTool` calls, rather than a reimplementation.
export
lintPathsToDiagQuads : StdlibIndex ->
  List String ->
  List String ->
  List String ->
  List String ->
  <IO> List (String, String, List Diag, Positions, List Decl)
lintPathsToDiagQuads idx disable only deny paths =
  map (lintFileDiagTripleParsed idx disable only deny) paths

-- Run the cross-file tier (`runCrossFileRules`) over the parses `quads`
-- already carries, honoring `only`/`disable` (inside `runCrossFileRules`),
-- inline `-- lint-disable-*` directives (`applySuppressionsMulti`, each
-- finding anchored to its own file), then `deny` promotion — mirroring
-- `lint_cmd.mdk`'s `crossFileJsonFindings` and the human-text
-- `runCrossFileReport` path.  Never renders; the caller folds the result into
-- the JSON triples via `mergeCrossFileIntoTriples`.
export
crossFileMcpFindings : List String ->
  List String ->
  List String ->
  List (String, String, List Diag, Positions, List Decl) ->
  List Finding
crossFileMcpFindings disable only deny quads =
  let parsedTriples = map quadToParseTriple quads
  let raw = runCrossFileRules only disable parsedTriples
  let suppressed = applySuppressionsMulti (map quadToSrc quads) raw
  applyFindingDeny deny suppressed

dropQuadParse : (String, String, List Diag, Positions, List Decl) ->
  (String, String, List Diag)
dropQuadParse (path, src, diags, _, _) = (path, src, diags)

anyTripleHasErr : List (String, String, List Diag) -> Bool
anyTripleHasErr [] = False
anyTripleHasErr ((_, _, diags) :: rest) =
  anyDiagErr diags || anyTripleHasErr rest

anyDiagErr : List Diag -> Bool
anyDiagErr [] = False
anyDiagErr (d :: rest) = diagIsError d || anyDiagErr rest

-- medaka_lint handler: run the lint pipeline (all rules, inline
-- `-- lint-disable-*` suppression, then the `disable`/`only`/`deny` filters)
-- over every path in `paths` and return the SAME `{"files":[...]}` envelope
-- `medaka_check`/`medaka lint --json` emit (via `cjAllToJson`) — one schema
-- across all three surfaces. Each `Finding` becomes a `Diag` via
-- `findingToDiag` (inside `lintFileDiagTripleParsed`), which stamps the lint
-- RULE NAME into the diagnostic's `code`. Cross-file rules participate too
-- (#2701 leg 3, parity with `medaka lint --json`): `lintPathsToDiagQuads`
-- keeps each path's parse, `crossFileMcpFindings` runs `runCrossFileRules`
-- over them, and `mergeCrossFileIntoTriples` folds each finding into its own
-- file's `diagnostics` array — its synthesized-entry fallback for a
-- duplicate's partner file lying outside `paths` is unreachable here, since
-- `paths` is exactly the set every cross-file rule runs over. `isError` is
-- true iff any diagnostic is a hard error (severity 1), including parse
-- errors and findings promoted by `deny`.
runLintTool : String -> String -> String -> Json -> <IO> Json
runLintTool _runtimeSrc _coreSrc _stdlibDir args = match pathsArg args
  None =>
    toolArgError
      "medaka_lint: missing or invalid argument — require 'paths' (array of strings)"
  Some paths =>
    let disable = lintNameListArg "disable" args
    let only = lintNameListArg "only" args
    let deny = lintNameListArg "deny" args
    -- at most once per REQUEST, not per path (see lintPathsToDiagQuads) — and
    -- not at all when `rule-stdlib-reimpl`, the sole `StdlibIndex` reader, is
    -- outside the active `disable`/`only` set (see `stdlibIndexNeeded`).
    let indexResult =
      if stdlibIndexNeeded only disable then
        buildStdlibIndexResult
      else
        Ok emptyStdlibIndex
    match indexResult
      Err (StdlibIndexError { path, source, diagnostic }) =>
        toolTextResult (cjAllToJson [(path, source, [diagnostic])]) True
      Ok idx =>
        let quads = lintPathsToDiagQuads idx disable only deny paths
        let triples = map dropQuadParse quads
        let cross = crossFileMcpFindings disable only deny quads
        let merged = mergeCrossFileIntoTriples cross triples
        toolTextResult (cjAllToJson merged) (anyTripleHasErr merged)

-- ── medaka_test tool ──────────────────────────────────────────────────────────

-- The engine `medaka_test` runs when the caller names none: native, the same
-- default `medaka test` has (`parseTestEngines`, tools/test_cmd.mdk), so an
-- agent and a human running the same file get the same verdict.  The optional
-- `engine` argument ("native" | "eval") opts into the interpreter.  The tool
-- description and the payload's `engine`/`note` fields are DERIVED from the
-- engine list that was asked for / actually ran, never a hand-written literal.
mcpTestDefaultEngines : List Engine
mcpTestDefaultEngines = [EngNative]

mcpTestEngineHasNative : List Engine -> Bool
mcpTestEngineHasNative [] = False
mcpTestEngineHasNative (EngNative :: _) = True
mcpTestEngineHasNative (_ :: rest) = mcpTestEngineHasNative rest

-- The `engine` argument: a missing key selects the default; a present value
-- must be the string "native" or "eval".  Anything else, including a non-string
-- value and an explicit null, is an argument error, not a silent fallback to the
-- default.
mcpTestEnginesArg : Json -> Result String (List Engine)
mcpTestEnginesArg args = match get "engine" args
  None => Ok mcpTestDefaultEngines
  Some (JString "native") => Ok [EngNative]
  Some (JString "eval") => Ok [EngInterp]
  Some (JString other) =>
    Err
      "medaka_test: unknown engine '\{other}' — 'engine' must be \"native\" (default) or \"eval\""
  Some _ =>
    Err
      "medaka_test: 'engine' must be a string, \"native\" (default) or \"eval\""

-- The caveat sentence, derived from `engines`: an interpreter-only run keeps
-- the original #81 warning; a run that includes the native engine says which
-- engine produced both its doctest and property verdicts.
mcpTestCaveat : List Engine -> String
mcpTestCaveat engines
  | mcpTestEngineHasNative engines =
    "Results are under the NATIVE backend, the same engine `medaka test` defaults to, for both doctests and property tests. If the native build is unavailable (no clang), engine \"eval\" asks for the interpreter instead."
  | otherwise =
    "⚠️ RESULTS ARE UNDER THE INTERPRETER (\{engineName EngInterp}), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."

mcpTestDescription : String
mcpTestDescription =
  "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. Runs under the native backend by default, like `medaka test` (one clang build per call); optional `engine` \"eval\" runs the interpreter instead. Bare `test \"…\"` decls are NOT run here."

-- inputSchema: `file` (path), required.
medakaTestSchema : Json
medakaTestSchema = jObject [
  ("type", JString "object"),
  (
    "properties",
    jObject [
      (
        "file",
        jObject [
          ("type", JString "string"),
          (
            "description",
            JString
              "Path to the .mdk file whose doctests (and property tests, if any) to run.",
          ),
        ],
      ),
      (
        "engine",
        jObject [
          ("type", JString "string"),
          ("enum", jArray [JString "native", JString "eval"]),
          (
            "description",
            JString
              "Execution engine for doctests and property tests. Default \"native\" (what `medaka test` defaults to); \"eval\" runs the interpreter.",
          ),
        ],
      ),
    ],
  ),
  ("required", jArray [JString "file"]),
]

exampleJson : (Example, ExResult) -> Json
-- Structurally identical to medaka_cli.mdk's `cliExampleJson` now that both
-- render an `ExResult` through the shared `exResultJsonFields`; the part worth
-- sharing already lives in tools/doctest.mdk, and each module owns its own
-- `--json` envelope (mcp.mdk is a CLI-independent server surface).
-- lint-disable-next-line rule-duplicate-body
exampleJson (ex, res) =
  jObject
    ([("line", JInt (exampleLine ex - 1)), ("input", JString (exampleInput ex))]
      ++ exResultJsonFields res)

doctestsJson : RunResult -> Json
doctestsJson run = jObject [
  ("total", JInt (runPassed run + runFailed run + runErrors run)),
  ("passed", JInt (runPassed run)),
  ("failed", JInt (runFailed run)),
  ("errors", JInt (runErrors run)),
  ("examples", jArray (map exampleJson (runDetails run))),
]

propJson : GradedProp -> Json
-- Structurally identical to medaka_cli.mdk's `cliTestReportJson`-side
-- `cliPropJson` (#2295's `medaka test --json`, slice 4) — both render the
-- same `PropResult` shape for their own independent JSON envelope; neither
-- module imports the other, so not worth a shared module for one 5-line fn.
-- lint-disable-next-line rule-duplicate-body
propJson row =
  let p = gradedPropRaw row
  jObject
    ([
        ("engine", JString (propResultEngine p)),
        ("name", JString (propResultName p)),
        ("status", JString (gradedPropStatus row)),
        ("rawStatus", JString (gradedPropRawStatus row)),
        ("detail", JString (propResultDetail p)),
        ("failureKind", propFailureKindJson (propResultFailureKind p)),
        ("seed", JInt (propResultSeed p)),
        ("cases", JInt (propResultCases p)),
      ]
      ++ issueField (gradedPropIssue row)
      ++ pinField (gradedPropPinDetail row))

issueField : Option Int -> List (String, Json)
issueField None = []
issueField (Some issue) = [("issue", JInt issue)]

pinField : Option String -> List (String, Json)
pinField None = []
pinField (Some detail) = [("pin", JString detail)]

allPropsPass : List GradedProp -> Bool
allPropsPass [] = True
allPropsPass (p :: rest) = gradedPropPassed p && allPropsPass rest

countPassProps : List GradedProp -> Int
countPassProps [] = 0
countPassProps (p :: rest) =
  (if propResultPassed (gradedPropRaw p) && gradedPropPassed p then 1 else 0)
    + countPassProps rest

countFailProps : List GradedProp -> Int
countFailProps [] = 0
countFailProps (p :: rest) =
  (if gradedPropPassed p then 0 else 1) + countFailProps rest

-- The first (a call runs exactly one engine) doctest run, keyed off whichever engine actually
-- ran it — `runTestReport` positionally tags each `RunResult` by the `Engine`
-- that produced it, so this never has to assume which one that was.
primaryDoctestRun : List (Engine, RunResult) -> RunResult
primaryDoctestRun [] = RunResult 0 0 0 0 []
primaryDoctestRun ((_, run) :: _) = run

-- The run OVERALL passed iff the module type-checked (or was exempted, #1443)
-- AND every engine's doctest run and every property passed.  Drives both the
-- `summary.ok` field and the result's `isError` flag.  A `Some` type error
-- means doctests/props never ran (mirrors `runTestReport`'s gate short-
-- circuit), so it alone forces `False` regardless of `runs`/`props` (both are
-- empty in that case anyway).
testReportOk : Option TestReportError ->
  List (Engine, RunResult) ->
  List GradedProp ->
  Bool
testReportOk typeError runs props =
  isNone typeError && allDoctestRunsOk runs && allPropsPass props

allDoctestRunsOk : List (Engine, RunResult) -> Bool
allDoctestRunsOk [] = True
allDoctestRunsOk ((_, run) :: rest) =
  runFailed run == 0 && runErrors run == 0 && allDoctestRunsOk rest

-- The engine name(s) that actually produced `runs` — DERIVED, never a literal
-- "eval": a hardcoded string would lie as soon as the engine is not the
-- interpreter.
doctestRunEngineNames : List (Engine, RunResult) -> List Engine
doctestRunEngineNames [] = []
doctestRunEngineNames ((e, _) :: rest) = e :: doctestRunEngineNames rest

-- `runs` is always a singleton (one `engine` per call), so the
-- top-level "engine" field is that one engine's name — derived from the list
-- that actually ran, never a bare literal.
primaryEngineName : List Engine -> String
primaryEngineName [] = "unknown"
primaryEngineName (e :: _) = engineName e

-- Setup, parse, and typecheck failures expose `typeError`; on rejection,
-- `doctests`/`properties`/`summary` are then the untouched empty defaults
-- (mirrors the CLI's `runTest`, which never reaches `driveAll` on a gate
-- failure either). Diagnostic messages and structured ranges are separate;
-- setup errors retain their original text.
typeErrorField : Option TestReportError -> List (String, Json)
typeErrorField None = []
typeErrorField (Some (TestSetupError errText)) =
  [("typeError", JString errText)]
typeErrorField (Some (TestDiagnosticError triples)) = [
  (
    "typeError",
    JString (joinWith "\n" (flatMap testDiagnosticMessages triples)),
  ),
  ("typeDiagnostics", jArray (map testDiagnosticFile triples)),
]

testDiagnosticMessages : (String, String, List Diag) -> List String
testDiagnosticMessages (_, _, diags) =
  map ((Diag _ _ message _ _ _) => message) (filter diagIsError diags)

testDiagnosticFile : (String, String, List Diag) -> Json
testDiagnosticFile (path, src, diags) = cjFileEntry path src diags

-- F7 (#1680/#1443): a distinct boolean field, present only when True — the
-- human `medaka test` arm announces this on stderr (`typecheckSkipNotice`,
-- tools.test_cmd.mdk); this is the machine-readable equivalent for a caller
-- of medaka_test, which has no stderr channel of its own to read that
-- announcement from.  Kept SEPARATE from the existing `note` field above
-- (the interpreter-engine caveat) rather than folded into it — `note` is a
-- fixed single-purpose string already described in the tool's own
-- description; overloading it with a second, unrelated fact would make both
-- harder for a machine consumer to parse reliably.
typecheckSkippedField : Bool -> List (String, Json)
typecheckSkippedField False = []
typecheckSkippedField True = [("typecheckSkipped", JBool True)]

-- #2339: `runTestTool` always calls `runTestReport` with `includeTestDecls =
-- False` (F3 — a panicking `test "…"` body must not crash the MCP server),
-- so the `test "…"` phase never runs here at all, and unlike
-- `typecheckSkippedField` above there is no live/absent case to distinguish
-- — the field is unconditional, always `true`, for exactly the one call site
-- that ever builds this envelope. It says in the JSON itself what previously
-- only the tool's prose description said, so a caller reading the envelope
-- alone (not the description) is not misled by `ok:true`/`summary` counts
-- that silently cover doctests+props only.
testDeclsSkippedField : List (String, Json)
testDeclsSkippedField = [("testDeclsSkipped", JBool True)]

-- The full structured result body.  `engine`/`note` carry the engine
-- caveat INTO the payload (not just the tool description) so a consumer that
-- never read the description is still told what these results cover — and,
-- like the description, both are DERIVED from the engines that actually ran
-- (`doctestRunEngineNames runs`) when the module type-checked, or from the
-- engines that WOULD have run (`requested`) when a type error short-
-- circuited the run before any engine touched it (`runs` is `[]` there, so
-- `doctestRunEngineNames runs` would wrongly read "unknown").
testReportJson : String ->
  List Engine ->
  Option TestReportError ->
  List (Engine, RunResult) ->
  List GradedProp ->
  Bool ->
  Json
testReportJson path requested typeError runs props typecheckSkipped =
  let engines =
    if isNone typeError then doctestRunEngineNames runs else requested
  jObject
    ([
        ("file", JString path),
        ("engine", JString (primaryEngineName engines)),
        ("note", JString (mcpTestCaveat engines)),
      ]
      ++ typeErrorField typeError
      ++ typecheckSkippedField typecheckSkipped
      ++ testDeclsSkippedField
      ++ [
        ("doctests", doctestsJson (primaryDoctestRun runs)),
        ("properties", jArray (map propJson props)),
        (
          "summary",
          jObject [
            (
              "passed",
              JInt (runPassed (primaryDoctestRun runs) + countPassProps props),
            ),
            (
              "failed",
              JInt
                (runFailed (primaryDoctestRun runs)
                  + runErrors (primaryDoctestRun runs)
                  + countFailProps props),
            ),
            ("knownRed", JInt (knownRedCountProps props)),
            ("ok", JBool (testReportOk typeError runs props)),
          ],
        ),
      ])

-- medaka_test handler: read `file`, run its doctests + props through the
-- non-printing structured reporter (tools.test_cmd.runTestReport), and return
-- the per-example/per-property JSON.  isError=true iff the module failed the
-- SAME typecheck gate `medaka test` gates on (#1443) or any example/property
-- failed (mirrors medaka_check's convention: isError flags a bad OUTCOME, with
-- the detail in the structured content).  A missing/unreadable file is an
-- argument error, not a crash.  Which engine(s) ran is reported per `engine`/
-- `note`, DERIVED from the requested `engine` (default native) — see the tool
-- description too.
runTestTool : String -> String -> String -> Json -> <IO> Json
runTestTool runtimeSrc coreSrc stdlibDir args = match fieldStr "file" args
  None =>
    toolArgError
      "medaka_test: missing or invalid argument — require 'file' (string)"
  Some path => match mcpTestEnginesArg args
    Err msg => toolArgError msg
    Ok engines => match readFile path
      Err e =>
        toolArgError
          (stringConcat ["medaka_test: cannot read file '", path, "': ", e])
      Ok tsrc => match parseResult tsrc
        -- #2295 (d): `runTestReport` also returns the `test "…"` phase's
        -- structured results (a 4th tuple element, for `medaka test --json`'s
        -- benefit) and (F7) whether the module was typecheck-exempt (a 5th) —
        -- this tool deliberately ignores the former (medaka_test covers
        -- doctests + props only, per #252/#1443) by passing `includeTestDecls =
        -- False`, which (F3) also means the test-decl phase is never EVALUATED
        -- here, not merely unreported — a panicking `test "…"` decl in the
        -- target file can no longer crash the MCP server on this path.

        Err err =>
          let failure =
            Some (TestDiagnosticError [(path, tsrc, [parseErrDiag path err])])
          toolTextResult
            (stringify (testReportJson path engines failure [] [] False))
            True
        Ok decls =>
          let (typeError, runs, props, _testResults, typecheckSkipped) =
            runTestGradedReportParts
              engines
              runtimeSrc
              coreSrc
              path
              tsrc
              (desugar decls)
              stdlibDir
              100
              None
              False
          toolTextResult
            (stringify
              (testReportJson
                path
                engines
                typeError
                runs
                props
                typecheckSkipped))
            (not (testReportOk typeError runs props))

-- ── tools/call handler ───────────────────────────────────────────────────────

handleToolsCall : String ->
  String ->
  String ->
  Json ->
  Json ->
  (Unit -> <IO> Option String) ->
  <IO> Unit
handleToolsCall runtimeSrc coreSrc stdlibDir idJson params stalenessCheck =
  match fieldStr "name" params
    None =>
      writeMessage (errorMsg idJson (0 - 32602) "tools/call: missing 'name'")
    Some name =>
      let args = fieldOr "arguments" params
      let _ = logMcpCall "tools/call" name (stringify args)
      let _ = selectToolProfile args
      match callTool runtimeSrc coreSrc stdlibDir name args
        None =>
          writeMessage
            (errorMsg
              idJson
              (0 - 32601)
              (stringConcat ["Unknown tool: ", name]))
        Some result =>
          let augmented = attachStaleness stalenessCheck result
          writeMessage (responseMsg idJson augmented)

-- The profile of the project holding the call's `file`, chosen afresh per call
-- (this server analyzes many projects).  An unreadable `[target]` leaves no
-- profile selected; `medaka_check` reports it.
selectToolProfile : Json -> <IO> Unit
selectToolProfile args = match fieldStr "file" args
  Some path =>
    let _ = carryProjectProfile None path
    ()
  None => selectedProfile := None

-- ── request dispatch ─────────────────────────────────────────────────────────

-- Handle one decoded JSON-RPC message.  Requests carry an `id` and get a
-- response; notifications have no `id` and get none — detected by whether the
-- `id` KEY IS PRESENT at all (`lookup`), not by `fieldOr`'s JNull default,
-- which can't tell "absent" from "explicitly null".  This id-presence check
-- gates EVERY recognized method uniformly (a no-id `ping`/`tools/call`/
-- `initialize` gets no reply, exactly like a no-id unrecognized method would).
-- An unrecognized *request* returns method-not-found (-32601); an unrecognized
-- *notification* is ignored.  A top-level batch array (`[{...},{...}]`) is not
-- a supported transport shape here — it gets one Invalid Request error rather
-- than being silently dropped.
dispatchMsg : String ->
  String ->
  String ->
  Json ->
  (Unit -> <IO> Option String) ->
  String ->
  <IO> Unit
dispatchMsg runtimeSrc coreSrc stdlibDir msg stalenessCheck serverVersion =
  match asArray msg
    Some _ =>
      writeMessage
        (errorMsg
          JNull
          (0 - 32600)
          "Invalid Request: batch requests are not supported")
    None => match methodOf msg
      None => logMcp "ignored: message has no string 'method' field"
      Some meth =>
        let params = fieldOr "params" msg
        -- tools/call gets its own richer line (tool name + args) inside
        -- handleToolsCall — don't double-log it here.
        let _ = if meth == "tools/call" then unit else logMcpCall meth "" ""
        if meth == "notifications/initialized" then
          unit
        else match get "id" msg
          None => unit  -- notification: no response for ANY method
          Some idJson =>
            if meth == "initialize" then
              writeMessage
                (responseMsg
                  idJson
                  (initializeResultFor (negotiateVersion msg) serverVersion))
            else if meth == "ping" then
              writeMessage (responseMsg idJson (jObject []))
            else if meth == "shutdown" then
              writeMessage (responseMsg idJson (jObject []))
            else if meth == "tools/list" then
              writeMessage (responseMsg idJson toolsListResult)
            else if meth == "tools/call" then
              handleToolsCall
                runtimeSrc
                coreSrc
                stdlibDir
                idJson
                params
                stalenessCheck
            else
              writeMessage
                (errorMsg
                  idJson
                  (0 - 32601)
                  (stringConcat ["Method not found: ", meth]))

-- ── read loop ────────────────────────────────────────────────────────────────

-- Parse and dispatch one input line.  Blank lines and malformed JSON are logged
-- to stderr and skipped, never crashing the stream.
handleLine : String ->
  String ->
  String ->
  String ->
  (Unit -> <IO> Option String) ->
  String ->
  <IO> Unit
handleLine runtimeSrc coreSrc stdlibDir raw stalenessCheck serverVersion =
  let line = stripCR raw
  if line == "" then
    unit
  else match parse line
    Err e => logMcp (stringConcat ["parse error (skipped): ", e])
    Ok msg =>
      dispatchMsg runtimeSrc coreSrc stdlibDir msg stalenessCheck serverVersion

-- The session loop: one JSON object per line until stdin EOF (clean shutdown).
serveLoop : String ->
  String ->
  String ->
  (Unit -> <IO> Option String) ->
  String ->
  <IO> Unit
serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion =
  match readLineOpt ()
    None => unit
    Some raw =>
      let _ =
        handleLine runtimeSrc coreSrc stdlibDir raw stalenessCheck serverVersion
      serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion

-- Public entry point for the driver (`runMcpCmd` in medaka_cli.mdk).  The prelude
-- sources + stdlib dir are threaded in so tools can run the compiler pipeline
-- (e.g. medaka_check resolves a `file` target's imports against stdlibDir).
-- `stalenessCheck` is medaka_cli.mdk's `sourceStalenessVerdict`, threaded down
-- as a closure (#846) — see the "staleness signal" section above.
-- `serverVersion` is medaka_cli.mdk's bare `medakaVersion` literal (issue
-- #74 W8), threaded down the same way rather than restating a literal here.
export
runMcpServer : String ->
  String ->
  String ->
  (Unit -> <IO> Option String) ->
  String ->
  <IO> Unit
runMcpServer runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion =
  let _ = logMcp "medaka mcp server start"
  serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion
# DESUGAR
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "parseSnapshotSyntax" false) (mem "snapshotSyntaxResult" false) (mem "snapshotSyntaxSnapshot" false))))
(DUse false (UseGroup ("tools" "syntax_queries") ((mem "symbolsFromRecovered" false) (mem "jPosition" false))))
(DUse false (UseGroup ("tools" "lsp_diagnostics") ((mem "diagnosticJsonOr" false))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "invalidExtent" false) (mem "invalidReason" false) (mem "invalidRegions" false) (mem "recoveredDiagnostics" false) (mem "recoveredCompleteness" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false) (mem "clampSourcePositionToOffset" false) (mem "sourceEndUtf16Position" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "stdlibExportsReader" false) (mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "cjFileEntry" false) (mem "parseErrDiag" false) (mem "diagIsError" false) (mem "Diag" true))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "typeAtPointsWithIndex" false) (mem "documentSymbols" false) (mem "definitionResult" false) (mem "definitionResultsWithIndex" false) (mem "referencesResult" false) (mem "emptyDocs" false) (mem "docsPut" false) (mem "uriOfPath" false) (mem "responseMsg" false) (mem "fieldOr" false) (mem "fieldStr" false) (mem "methodOf" false) (mem "unit" false))))
(DUse false (UseGroup ("tools" "lint_cmd") ((mem "quadToParseTriple" false) (mem "quadToSrc" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" false) (mem "lintFileDiagTripleParsed" false) (mem "mergeCrossFileIntoTriples" false) (mem "runCrossFileRules" false) (mem "applySuppressionsMulti" false) (mem "applyFindingDeny" false) (mem "splitLintNames" false) (mem "buildStdlibIndexResult" false) (mem "StdlibIndexError" true) (mem "emptyStdlibIndex" false) (mem "stdlibIndexNeeded" false) (mem "StdlibIndex" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestGradedReportParts" false) (mem "TestReportError" true))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "lastPreludeStaleLine" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "carryProjectProfile" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "exResultJsonFields" false) (mem "RunResult" false) (mem "Engine" true) (mem "engineName" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultSeed" false) (mem "propResultCases" false) (mem "propResultFailureKind" false))))
(DUse false (UseGroup ("tools" "eval_props") ((mem "propFailureKindJson" false))))
(DUse false (UseGroup ("tools" "test_pins_report") ((mem "GradedProp" false) (mem "gradedPropRaw" false) (mem "gradedPropPassed" false) (mem "gradedPropStatus" false) (mem "gradedPropRawStatus" false) (mem "gradedPropIssue" false) (mem "gradedPropPinDetail" false) (mem "knownRedCountProps" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "zipWith" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "findAll" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EVar "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "logMcpCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "logMcpCall" ((PVar "method") (PVar "name") (PVar "args")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_MCP_LOG"))) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "unit")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "ts") (EApp (EVar "floatToString") (EApp (EVar "wallTimeSec") (ELit LUnit)))) (DoLet false false (PVar "line") (EApp (EVar "stringConcat") (EListLit (EVar "ts") (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "method"))) (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (ELit (LString "\t")) (EVar "args") (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (EVar "unit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "log write failed: ")) (EVar "e")))))))))))
(DTypeSig false "attachStaleness" (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))
(DFunDef false "attachStaleness" ((PVar "stalenessCheck") (PVar "result")) (EBlock (DoLet false false (PVar "withBinary") (EMatch (EApp (EVar "stalenessCheck") (ELit LUnit)) (arm (PCon "None") () (EVar "result")) (arm (PCon "Some" (PVar "compilerDir")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "staleBinary"))) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "this server's binary predates the compiler source at ")) (EVar "compilerDir") (ELit (LString " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).")))))) (EVar "result"))))) (DoExpr (EMatch (EApp (EVar "lastPreludeStaleLine") (ELit LUnit)) (arm (PCon "None") () (EVar "withBinary")) (arm (PCon "Some" (PVar "line")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "stalePreludeInterface"))) (EApp (EVar "JString") (EVar "line"))) (EVar "withBinary")))))))
(DTypeSig false "jsonObjectAppend" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "jsonObjectAppend" ((PVar "key") (PVar "value") (PCon "JObject" (PVar "pairs"))) (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EBinOp "++" (EApp (EVar "jsonPairsToList") (EVar "pairs")) (EListLit (ETuple (EVar "key") (EVar "value")))))))
(DFunDef false "jsonObjectAppend" (PWild PWild (PVar "other")) (EVar "other"))
(DTypeSig false "jsonPairsToList" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "jsonPairsToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonPairsToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonPairsToListGo" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))))
(DFunDef false "jsonPairsToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonPairsToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "initializeResultFor" ((PVar "protocolVersion") (PVar "serverVersion")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "protocolVersion"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "serverVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns structured JSON using zero-based UTF-16 positions (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. Incomplete source returns recoverable declarations; structuredContent reports completeness, invalid regions and diagnostics."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_references"))) (ELit (LString "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line` and UTF-16 `col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies."))) (EVar "medakaReferencesSchema")) (EVar "runReferencesTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (EVar "mcpTestDescription")) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
(DTypeSig false "toolDescriptor" (TyFun (TyCon "McpTool") (TyCon "Json")))
(DFunDef false "toolDescriptor" ((PCon "McpTool" (PVar "name") (PVar "desc") (PVar "schema") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (EVar "desc"))) (ETuple (ELit (LString "inputSchema")) (EVar "schema")))))
(DTypeSig false "callTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Json")))))))))
(DFunDef false "callTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "name") (PVar "args")) (EApp (EApp (EVar "map") (ELam ((PCon "McpTool" PWild PWild PWild (PVar "handler"))) (EApp (EApp (EApp (EApp (EVar "handler") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "args")))) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "mcpTools"))))
(DTypeSig false "lookupTool" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "McpTool")) (TyApp (TyCon "Option") (TyCon "McpTool")))))
(DFunDef false "lookupTool" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTool" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EMatch (EVar "t") (arm (PCon "McpTool" (PVar "n") PWild PWild PWild) () (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "ts"))))))
(DTypeSig false "medakaCheckSchema" (TyCon "Json"))
(DFunDef false "medakaCheckSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to check."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to check (no file on disk).")))))))))))))
(DTypeSig false "syntheticSourceName" (TyCon "String"))
(DFunDef false "syntheticSourceName" () (ELit (LString "<source>")))
(DTypeSig false "toolTextResult" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Json"))))
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EApp (EApp (EVar "toolTextFields") (EVar "text")) (EVar "isErr"))))
(DTypeSig false "toolTextFields" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "toolTextFields" ((PVar "text") (PVar "isErr")) (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr")))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_check: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "toolArgError") (EBinOp "++" (ELit (LString "medaka_check: error: ")) (EVar "m")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None"))) (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (ELit (LString ""))) (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "fieldSymbol" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "fieldSymbol" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "symbol"))) (EVar "args")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "lineTextAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lineTextAt" ((PVar "src") (PVar "line")) (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EVar "src")) (EVar "line")))
(DTypeSig false "lineTextAtIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lineTextAtIndexed" ((PVar "index") (PVar "src") (PVar "line")) (EApp (EApp (EVar "map") (ELam ((PVar "start")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EApp (EApp (EApp (EVar "lineTextEnd") (EApp (EVar "stringToChars") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (EVar "start"))) (EVar "src")))) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0)))))
(DTypeSig false "lineTextEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineTextEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\r")))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identTokenRe" (TyCon "Regex"))
(DFunDef false "identTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "[A-Za-z0-9_']+"))))
(DTypeSig false "identifiersInLine" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identifiersInLine" ((PVar "text")) (EApp (EApp (EVar "map") (EApp (EVar "identPair") (EApp (EVar "indexSource") (EVar "text")))) (EApp (EApp (EVar "findAll") (EVar "identTokenRe")) (EVar "text"))))
(DTypeSig false "identPair" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Match") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identPair" ((PVar "index") (PVar "m")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EFieldAccess (EVar "m") "start")) (arm (PCon "Some" (PTuple PWild (PVar "col"))) () (ETuple (EFieldAccess (EVar "m") "text") (EVar "col"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "identifier regex returned a non-source boundary"))))))
(DTypeSig false "symbolColsInSource" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "symbolColsInSource" ((PVar "index") (PVar "line") (PVar "text") (PVar "symbol")) (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "start")) () (EApp (EApp (EVar "symbolColsGo") (EApp (EApp (EVar "map") (EApp (EApp (EVar "identPairAt") (EVar "index")) (EVar "start"))) (EApp (EApp (EVar "findAll") (EVar "identTokenRe")) (EVar "text")))) (EVar "symbol")))))
(DTypeSig false "identPairAt" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "identPairAt" ((PVar "index") (PVar "start") (PVar "m")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EBinOp "+" (EVar "start") (EFieldAccess (EVar "m") "start"))) (arm (PCon "Some" (PTuple PWild (PVar "col"))) () (ETuple (EFieldAccess (EVar "m") "text") (EVar "col"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "identifier regex returned a non-source boundary"))))))
(DTypeSig false "symbolColsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsGo" ((PList) PWild) (EListLit))
(DFunDef false "symbolColsGo" ((PCons (PTuple (PVar "name") (PVar "col")) (PVar "rest")) (PVar "symbol")) (EIf (EBinOp "==" (EVar "name") (EVar "symbol")) (EBinOp "::" (EVar "col") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "describeIdentifiers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "describeIdentifiers" ((PList)) (ELit (LString "(none)")))
(DFunDef false "describeIdentifiers" ((PVar "ids")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "identColDesc")) (EVar "ids"))))
(DTypeSig false "identColDesc" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "identColDesc" ((PVar "pair")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "fst") (EVar "pair")) (ELit (LString " (col ")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "pair"))) (ELit (LString ")")))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based UTF-16 column. Alternative to 'symbol' — provide exactly one."))))))) (ETuple (ELit (LString "symbol")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EVar "index")) (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'"))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EApp (EApp (EVar "symbolColsInSource") (EVar "index")) (EVar "line")) (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "' — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText")))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PVar "cols") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtManyCols") (EVar "index")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols"))))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "typeAtOneCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "typeAtOneCol" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EApp (EVar "typeAtMissNote") (EVar "src")) (EVar "line")) (EVar "col"))) (EVar "False")))))
(DTypeSig false "typeAtMissNote" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "typeAtMissNote" ((PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString " — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))
(DTypeSig false "typeAtManyCols" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Json")))))))))))
(DFunDef false "typeAtManyCols" ((PVar "index") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EBlock (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "'")) (EVar "symbol") (ELit (LString "' is ambiguous on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " — ")) (EApp (EVar "intToString") (EApp (EVar "length") (EVar "cols"))) (ELit (LString " matches:"))))) (DoLet false false (PVar "answers") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPointsWithIndex") (EVar "index")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))) (DoLet false false (PVar "bodies") (EApp (EApp (EApp (EVar "zipWith") (EVar "typeAtColLine")) (EVar "cols")) (EVar "answers"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "header") (EVar "bodies")))) (EVar "False")))))
(DTypeSig false "typeAtColLine" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "typeAtColLine" ((PVar "col") (PCon "Some" (PVar "ty"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": ")) (EVar "ty"))))
(DFunDef false "typeAtColLine" ((PVar "col") (PCon "None")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": no symbol")))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "reasonName" (TyFun (TyCon "InvalidReason") (TyCon "String")))
(DFunDef false "reasonName" ((PCon "InvalidDeclaration")) (ELit (LString "invalidDeclaration")))
(DFunDef false "reasonName" ((PCon "TerminalLexError")) (ELit (LString "terminalLexError")))
(DFunDef false "reasonName" ((PCon "UnclosedDelimiter")) (ELit (LString "unclosedDelimiter")))
(DFunDef false "reasonName" ((PCon "MismatchedDelimiter")) (ELit (LString "mismatchedDelimiter")))
(DFunDef false "reasonName" ((PCon "UntrustedBoundary")) (ELit (LString "untrustedBoundary")))
(DFunDef false "reasonName" ((PCon "RecoveryBudget")) (ELit (LString "recoveryBudget")))
(DTypeSig false "stopName" (TyFun (TyCon "RecoveryStop") (TyCon "String")))
(DFunDef false "stopName" ((PCon "ReachedEnd")) (ELit (LString "reachedEnd")))
(DFunDef false "stopName" ((PCon "StoppedLexically")) (ELit (LString "stoppedLexically")))
(DFunDef false "stopName" ((PCon "StoppedDelimiter")) (ELit (LString "stoppedDelimiter")))
(DFunDef false "stopName" ((PCon "StoppedBoundary")) (ELit (LString "stoppedBoundary")))
(DFunDef false "stopName" ((PCon "ExhaustedBudget")) (ELit (LString "exhaustedBudget")))
(DTypeSig false "regionPosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "regionPosition" ((PVar "index") (PVar "off")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "off")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "symbolsResult" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "revision") (EApp (EApp (EApp (EApp (EVar "SourceRevision") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "None")) (ELit (LInt 0))) (EVar "src"))) (DoLet false false (PVar "syntax") (EApp (EVar "parseSnapshotSyntax") (EVar "revision"))) (DoLet false false (PVar "result") (EApp (EVar "snapshotSyntaxResult") (EVar "syntax"))) (DoLet false false (PTuple (PVar "completeness") (PVar "stop")) (EMatch (EApp (EVar "recoveredCompleteness") (EVar "result")) (arm (PCon "Complete") () (ETuple (ELit (LString "complete")) (EVar "JNull"))) (arm (PCon "Partial" (PVar "why")) () (ETuple (ELit (LString "partial")) (EApp (EVar "JString") (EApp (EVar "stopName") (EVar "why"))))))) (DoLet false false (PTuple (PVar "regions") (PVar "diagnostics")) (EMatch (EApp (EVar "snapshotSyntaxSnapshot") (EVar "syntax")) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EVar "sourceEndUtf16Position") (EVar "src"))) (DoExpr (ETuple (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (ELit (LInt 0)))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (ELit (LInt 0))))))) (ETuple (ELit (LString "end")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (ELit (LString "recoveryBudget"))))))) (EListLit))))) (arm (PCon "Some" (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index"))) () (ETuple (EApp (EApp (EVar "map") (ELam ((PVar "region")) (EMatch (EApp (EVar "invalidExtent") (EVar "region")) (arm (PCon "SourceExtent" (PVar "start") (PVar "end")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "regionPosition") (EVar "index")) (EVar "start"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "regionPosition") (EVar "index")) (EVar "end"))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (EApp (EVar "reasonName") (EApp (EVar "invalidReason") (EVar "region"))))))))))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EVar "index")) (EVar "JNull")) (EApp (EApp (EVar "parseDiagnosticToDiag") (EVar "path")) (EVar "d"))))) (EApp (EVar "recoveredDiagnostics") (EVar "result"))))))) (DoLet false false (PVar "metadata") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "origin")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "version")) (EVar "JNull")) (ETuple (ELit (LString "generation")) (EApp (EVar "JInt") (ELit (LInt 0))))))) (ETuple (ELit (LString "completeness")) (EApp (EVar "JString") (EVar "completeness"))) (ETuple (ELit (LString "stop")) (EVar "stop")) (ETuple (ELit (LString "invalidRegions")) (EApp (EVar "jArray") (EVar "regions"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diagnostics")))))) (DoExpr (EMatch (EApp (EApp (EVar "symbolsFromRecovered") (EVar "revision")) (EVar "syntax")) (arm (PCon "Err" PWild) () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: snapshot mismatch")))) (arm (PCon "Ok" (PVar "symbols")) () (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "toolTextFields") (EApp (EVar "stringify") (EApp (EVar "jArray") (EVar "symbols")))) (EVar "False")) (EListLit (ETuple (ELit (LString "structuredContent")) (EVar "metadata"))))))))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "symbolsResult") (EVar "path")) (EVar "src")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EVar "medakaTypeAtSchema"))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "definitionAtCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "definitionAtCol" ((PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))) (arm (PCon "JNull") () (EApp (EApp (EApp (EVar "definitionMissNote") (EVar "line")) (EApp (EVar "Some") (EVar "col"))) (EVar "src"))) (arm (PVar "hit") () (EVar "hit"))))
(DTypeSig false "definitionMissNote" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "definitionMissNote" ((PVar "line") (PVar "maybeCol") (PVar "src")) (EBlock (DoLet false false (PVar "posDesc") (EMatch (EVar "maybeCol") (arm (PCon "Some" (PVar "col")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line"))))))) (DoExpr (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at ")) (EVar "posDesc")))))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at ")) (EVar "posDesc"))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))))))
(DTypeSig false "identPairJson" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "Json")))
(DFunDef false "identPairJson" ((PVar "pair")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "fst") (EVar "pair")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "snd") (EVar "pair")))))))
(DTypeSig false "definitionManyCols" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Json"))))))))
(DFunDef false "definitionManyCols" ((PVar "index") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "ambiguous")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "symbol")) (EApp (EVar "JString") (EVar "symbol"))) (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "zipWith") (EVar "definitionOneMatch")) (EVar "cols")) (EApp (EApp (EApp (EApp (EApp (EVar "definitionResultsWithIndex") (EVar "index")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))))))))
(DTypeSig false "definitionOneMatch" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "definitionOneMatch" ((PVar "col") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EVar "col"))) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EVar "index")) (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'")))))))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EApp (EApp (EVar "symbolColsInSource") (EVar "index")) (EVar "line")) (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "'")))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PVar "cols") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionManyCols") (EVar "index")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols")))) (EVar "False"))))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "medakaReferencesSchema" (TyCon "Json"))
(DFunDef false "medakaReferencesSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based UTF-16 column of the position (first column is 0)."))))))) (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Include the symbol's own declaration site in the result. Default true.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "referencesParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Json")))))
(DFunDef false "referencesParams" ((PVar "line") (PVar "col") (PVar "includeDecl")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "context")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "JBool") (EVar "includeDecl")))))))))
(DTypeSig false "runReferencesTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runReferencesTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_references: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "includeDecl") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "includeDeclaration"))) (EVar "True")) (EVar "args"))) (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EApp (EApp (EApp (EVar "referencesParams") (EVar "line")) (EVar "col")) (EVar "includeDecl"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EVar "result"))) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EVar "index")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "offset")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString ", col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "None") () (ELit (LString "unknown position"))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" (PVar "formatted")) () (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
(DTypeSig false "runFmtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runFmtTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "check"))) (EVar "False")) (EVar "args"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src")))))))
(DTypeSig false "medakaLintSchema" (TyCon "Json"))
(DFunDef false "medakaLintSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "paths")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "array")))) (ETuple (ELit (LString "items")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string"))))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Paths to .mdk files to lint."))))))) (ETuple (ELit (LString "deny")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to promote to error severity (mirrors --deny)."))))))) (ETuple (ELit (LString "only")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only)."))))))) (ETuple (ELit (LString "disable")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to suppress (mirrors --disable).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "paths")))))))))
(DTypeSig false "jsonArrToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "jsonArrToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonArrToListGo" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "jsonArrToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pathsArg" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pathsArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "paths"))) (EVar "args")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asArray") (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "arr")) () (EApp (EVar "allJsonStrings") (EApp (EVar "jsonArrToList") (EVar "arr"))))))))
(DTypeSig false "allJsonStrings" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allJsonStrings" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allJsonStrings" ((PCons (PVar "j") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "asString") (EVar "j")) (EApp (EVar "allJsonStrings") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "s")) (PCon "Some" (PVar "ss"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "s") (EVar "ss")))) (arm PWild () (EVar "None"))))
(DTypeSig false "lintNameListArg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNameListArg" ((PVar "key") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (EVar "key")) (EVar "args")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PLit (LString ""))) () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "splitLintNames") (EVar "s")))))
(DTypeSig true "lintPathsToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "lintPathsToDiagQuads" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "paths")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny"))) (EVar "paths")))
(DTypeSig true "crossFileMcpFindings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "crossFileMcpFindings" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "quads")) (EBlock (DoLet false false (PVar "parsedTriples") (EApp (EApp (EVar "map") (EVar "quadToParseTriple")) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "only")) (EVar "disable")) (EVar "parsedTriples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "suppressed")))))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "indexResult") (EIf (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EVar "disable")) (EVar "buildStdlibIndexResult") (EApp (EVar "Ok") (EVar "emptyStdlibIndex")))) (DoExpr (EMatch (EVar "indexResult") (arm (PCon "Err" (PRec "StdlibIndexError" ((rf "path" None) (rf "source" None) (rf "diagnostic" None)) false)) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "path") (EVar "source") (EListLit (EVar "diagnostic")))))) (EVar "True"))) (arm (PCon "Ok" (PVar "idx")) () (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagQuads") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EVar "crossFileMcpFindings") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "cross")) (EVar "triples"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "merged"))) (EApp (EVar "anyTripleHasErr") (EVar "merged"))))))))))))
(DTypeSig false "mcpTestDefaultEngines" (TyApp (TyCon "List") (TyCon "Engine")))
(DFunDef false "mcpTestDefaultEngines" () (EListLit (EVar "EngNative")))
(DTypeSig false "mcpTestEngineHasNative" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "Bool")))
(DFunDef false "mcpTestEngineHasNative" ((PList)) (EVar "False"))
(DFunDef false "mcpTestEngineHasNative" ((PCons (PCon "EngNative") PWild)) (EVar "True"))
(DFunDef false "mcpTestEngineHasNative" ((PCons PWild (PVar "rest"))) (EApp (EVar "mcpTestEngineHasNative") (EVar "rest")))
(DTypeSig false "mcpTestEnginesArg" (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "mcpTestEnginesArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "engine"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "mcpTestDefaultEngines"))) (arm (PCon "Some" (PCon "JString" (PLit (LString "native")))) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PCon "Some" (PCon "JString" (PLit (LString "eval")))) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp")))) (arm (PCon "Some" (PCon "JString" (PVar "other"))) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka_test: unknown engine '")) (EApp (EVar "display") (EVar "other"))) (ELit (LString "' — 'engine' must be \"native\" (default) or \"eval\""))))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "medaka_test: 'engine' must be a string, \"native\" (default) or \"eval\""))))))
(DTypeSig false "mcpTestCaveat" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "mcpTestCaveat" ((PVar "engines")) (EIf (EApp (EVar "mcpTestEngineHasNative") (EVar "engines")) (ELit (LString "Results are under the NATIVE backend, the same engine `medaka test` defaults to, for both doctests and property tests. If the native build is unavailable (no clang), engine \"eval\" asks for the interpreter instead.")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "⚠️ RESULTS ARE UNDER THE INTERPRETER (")) (EApp (EVar "display") (EApp (EVar "engineName") (EVar "EngInterp")))) (ELit (LString "), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mcpTestDescription" (TyCon "String"))
(DFunDef false "mcpTestDescription" () (ELit (LString "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. Runs under the native backend by default, like `medaka test` (one clang build per call); optional `engine` \"eval\" runs the interpreter instead. Bare `test \"…\"` decls are NOT run here.")))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run."))))))) (ETuple (ELit (LString "engine")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "enum")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "native"))) (EApp (EVar "JString") (ELit (LString "eval")))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Execution engine for doctests and property tests. Default \"native\" (what `medaka test` defaults to); \"eval\" runs the interpreter.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "exampleLine") (EVar "ex")) (ELit (LInt 1))))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultJsonFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "GradedProp") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "row")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "propResultEngine") (EVar "p")))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedPropStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedPropRawStatus") (EVar "row")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EApp (EVar "propResultFailureKind") (EVar "p")))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EApp (EVar "propResultSeed") (EVar "p")))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EApp (EVar "propResultCases") (EVar "p"))))) (EApp (EVar "issueField") (EApp (EVar "gradedPropIssue") (EVar "row")))) (EApp (EVar "pinField") (EApp (EVar "gradedPropPinDetail") (EVar "row"))))))))
(DTypeSig false "issueField" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "issueField" ((PCon "None")) (EListLit))
(DFunDef false "issueField" ((PCon "Some" (PVar "issue"))) (EListLit (ETuple (ELit (LString "issue")) (EApp (EVar "JInt") (EVar "issue")))))
(DTypeSig false "pinField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "pinField" ((PCon "None")) (EListLit))
(DFunDef false "pinField" ((PCon "Some" (PVar "detail"))) (EListLit (ETuple (ELit (LString "pin")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EApp (EVar "gradedPropRaw") (EVar "p"))) (EApp (EVar "gradedPropPassed") (EVar "p"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedPropPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "primaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "primaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "primaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "testReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))))
(DFunDef false "testReportOk" ((PVar "typeError") (PVar "runs") (PVar "props")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "allDoctestRunsOk") (EVar "runs"))) (EApp (EVar "allPropsPass") (EVar "props"))))
(DTypeSig false "allDoctestRunsOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "Bool")))
(DFunDef false "allDoctestRunsOk" ((PList)) (EVar "True"))
(DFunDef false "allDoctestRunsOk" ((PCons (PTuple PWild (PVar "run")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "allDoctestRunsOk") (EVar "rest"))))
(DTypeSig false "doctestRunEngineNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "Engine"))))
(DFunDef false "doctestRunEngineNames" ((PList)) (EListLit))
(DFunDef false "doctestRunEngineNames" ((PCons (PTuple (PVar "e") PWild) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "doctestRunEngineNames") (EVar "rest"))))
(DTypeSig false "primaryEngineName" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "primaryEngineName" ((PList)) (ELit (LString "unknown")))
(DFunDef false "primaryEngineName" ((PCons (PVar "e") PWild)) (EApp (EVar "engineName") (EVar "e")))
(DTypeSig false "typeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "typeErrorField" ((PCon "Some" (PCon "TestSetupError" (PVar "errText")))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DFunDef false "typeErrorField" ((PCon "Some" (PCon "TestDiagnosticError" (PVar "triples")))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "flatMap") (EVar "testDiagnosticMessages")) (EVar "triples"))))) (ETuple (ELit (LString "typeDiagnostics")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "testDiagnosticFile")) (EVar "triples"))))))
(DTypeSig false "testDiagnosticMessages" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testDiagnosticMessages" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "map") (ELam ((PCon "Diag" PWild PWild (PVar "message") PWild PWild PWild)) (EVar "message"))) (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "testDiagnosticFile" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "testDiagnosticFile" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig false "typecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "typecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testDeclsSkippedField" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))
(DFunDef false "testDeclsSkippedField" () (EListLit (ETuple (ELit (LString "testDeclsSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyCon "Bool") (TyCon "Json"))))))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "requested") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "engines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "doctestRunEngineNames") (EVar "runs")) (EVar "requested"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "primaryEngineName") (EVar "engines")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "mcpTestCaveat") (EVar "engines"))))) (EApp (EVar "typeErrorField") (EVar "typeError"))) (EApp (EVar "typecheckSkippedField") (EVar "typecheckSkipped"))) (EVar "testDeclsSkippedField")) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "knownRed")) (EApp (EVar "JInt") (EApp (EVar "knownRedCountProps") (EVar "props")))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "mcpTestEnginesArg") (EVar "args")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "toolArgError") (EVar "msg"))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "err")) () (EBlock (DoLet false false (PVar "failure") (EApp (EVar "Some") (EApp (EVar "TestDiagnosticError") (EListLit (ETuple (EVar "path") (EVar "tsrc") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "err")))))))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "engines")) (EVar "failure")) (EListLit)) (EListLit)) (EVar "False")))) (EVar "True"))))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "_testResults") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestGradedReportParts") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EApp (EVar "desugar") (EVar "decls"))) (EVar "stdlibDir")) (ELit (LInt 100))) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "engines")) (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "typecheckSkipped")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params") (PVar "stalenessCheck")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "logMcpCall") (ELit (LString "tools/call"))) (EVar "name")) (EApp (EVar "stringify") (EVar "args")))) (DoLet false false PWild (EApp (EVar "selectToolProfile") (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EVar "args")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EBlock (DoLet false false (PVar "augmented") (EApp (EApp (EVar "attachStaleness") (EVar "stalenessCheck")) (EVar "result"))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "augmented"))))))))))))
(DTypeSig false "selectToolProfile" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "selectToolProfile" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "path"))) (DoExpr (ELit LUnit)))) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None")))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EVar "unit") (EApp (EApp (EApp (EVar "logMcpCall") (EVar "meth")) (ELit (LString ""))) (ELit (LString ""))))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "get") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))) (EVar "serverVersion")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EVar "stalenessCheck")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg")) (EVar "stalenessCheck")) (EVar "serverVersion"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw")) (EVar "stalenessCheck")) (EVar "serverVersion"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))
# MARK
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "parseSnapshotSyntax" false) (mem "snapshotSyntaxResult" false) (mem "snapshotSyntaxSnapshot" false))))
(DUse false (UseGroup ("tools" "syntax_queries") ((mem "symbolsFromRecovered" false) (mem "jPosition" false))))
(DUse false (UseGroup ("tools" "lsp_diagnostics") ((mem "diagnosticJsonOr" false))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "invalidExtent" false) (mem "invalidReason" false) (mem "invalidRegions" false) (mem "recoveredDiagnostics" false) (mem "recoveredCompleteness" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false) (mem "clampSourcePositionToOffset" false) (mem "sourceEndUtf16Position" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "stdlibExportsReader" false) (mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "cjFileEntry" false) (mem "parseErrDiag" false) (mem "diagIsError" false) (mem "Diag" true))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "typeAtPointsWithIndex" false) (mem "documentSymbols" false) (mem "definitionResult" false) (mem "definitionResultsWithIndex" false) (mem "referencesResult" false) (mem "emptyDocs" false) (mem "docsPut" false) (mem "uriOfPath" false) (mem "responseMsg" false) (mem "fieldOr" false) (mem "fieldStr" false) (mem "methodOf" false) (mem "unit" false))))
(DUse false (UseGroup ("tools" "lint_cmd") ((mem "quadToParseTriple" false) (mem "quadToSrc" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" false) (mem "lintFileDiagTripleParsed" false) (mem "mergeCrossFileIntoTriples" false) (mem "runCrossFileRules" false) (mem "applySuppressionsMulti" false) (mem "applyFindingDeny" false) (mem "splitLintNames" false) (mem "buildStdlibIndexResult" false) (mem "StdlibIndexError" true) (mem "emptyStdlibIndex" false) (mem "stdlibIndexNeeded" false) (mem "StdlibIndex" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestGradedReportParts" false) (mem "TestReportError" true))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "lastPreludeStaleLine" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "carryProjectProfile" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "exResultJsonFields" false) (mem "RunResult" false) (mem "Engine" true) (mem "engineName" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultSeed" false) (mem "propResultCases" false) (mem "propResultFailureKind" false))))
(DUse false (UseGroup ("tools" "eval_props") ((mem "propFailureKindJson" false))))
(DUse false (UseGroup ("tools" "test_pins_report") ((mem "GradedProp" false) (mem "gradedPropRaw" false) (mem "gradedPropPassed" false) (mem "gradedPropStatus" false) (mem "gradedPropRawStatus" false) (mem "gradedPropIssue" false) (mem "gradedPropPinDetail" false) (mem "knownRedCountProps" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "zipWith" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "findAll" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EDictApp "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "logMcpCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "logMcpCall" ((PVar "method") (PVar "name") (PVar "args")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_MCP_LOG"))) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "unit")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "ts") (EApp (EVar "floatToString") (EApp (EVar "wallTimeSec") (ELit LUnit)))) (DoLet false false (PVar "line") (EApp (EVar "stringConcat") (EListLit (EVar "ts") (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "method"))) (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (ELit (LString "\t")) (EVar "args") (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (EVar "unit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "log write failed: ")) (EVar "e")))))))))))
(DTypeSig false "attachStaleness" (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))
(DFunDef false "attachStaleness" ((PVar "stalenessCheck") (PVar "result")) (EBlock (DoLet false false (PVar "withBinary") (EMatch (EApp (EVar "stalenessCheck") (ELit LUnit)) (arm (PCon "None") () (EVar "result")) (arm (PCon "Some" (PVar "compilerDir")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "staleBinary"))) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "this server's binary predates the compiler source at ")) (EVar "compilerDir") (ELit (LString " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).")))))) (EVar "result"))))) (DoExpr (EMatch (EApp (EVar "lastPreludeStaleLine") (ELit LUnit)) (arm (PCon "None") () (EVar "withBinary")) (arm (PCon "Some" (PVar "line")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "stalePreludeInterface"))) (EApp (EVar "JString") (EVar "line"))) (EVar "withBinary")))))))
(DTypeSig false "jsonObjectAppend" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "jsonObjectAppend" ((PVar "key") (PVar "value") (PCon "JObject" (PVar "pairs"))) (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EBinOp "++" (EApp (EVar "jsonPairsToList") (EVar "pairs")) (EListLit (ETuple (EVar "key") (EVar "value")))))))
(DFunDef false "jsonObjectAppend" (PWild PWild (PVar "other")) (EVar "other"))
(DTypeSig false "jsonPairsToList" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "jsonPairsToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonPairsToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonPairsToListGo" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))))
(DFunDef false "jsonPairsToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonPairsToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "initializeResultFor" ((PVar "protocolVersion") (PVar "serverVersion")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "protocolVersion"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "serverVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns structured JSON using zero-based UTF-16 positions (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. Incomplete source returns recoverable declarations; structuredContent reports completeness, invalid regions and diagnostics."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based UTF-16 code units) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_references"))) (ELit (LString "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line` and UTF-16 `col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies."))) (EVar "medakaReferencesSchema")) (EVar "runReferencesTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (EVar "mcpTestDescription")) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
(DTypeSig false "toolDescriptor" (TyFun (TyCon "McpTool") (TyCon "Json")))
(DFunDef false "toolDescriptor" ((PCon "McpTool" (PVar "name") (PVar "desc") (PVar "schema") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (EVar "desc"))) (ETuple (ELit (LString "inputSchema")) (EVar "schema")))))
(DTypeSig false "callTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Json")))))))))
(DFunDef false "callTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "name") (PVar "args")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "McpTool" PWild PWild PWild (PVar "handler"))) (EApp (EApp (EApp (EApp (EVar "handler") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "args")))) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "mcpTools"))))
(DTypeSig false "lookupTool" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "McpTool")) (TyApp (TyCon "Option") (TyCon "McpTool")))))
(DFunDef false "lookupTool" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTool" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EMatch (EVar "t") (arm (PCon "McpTool" (PVar "n") PWild PWild PWild) () (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "ts"))))))
(DTypeSig false "medakaCheckSchema" (TyCon "Json"))
(DFunDef false "medakaCheckSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to check."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to check (no file on disk).")))))))))))))
(DTypeSig false "syntheticSourceName" (TyCon "String"))
(DFunDef false "syntheticSourceName" () (ELit (LString "<source>")))
(DTypeSig false "toolTextResult" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Json"))))
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EApp (EApp (EVar "toolTextFields") (EVar "text")) (EVar "isErr"))))
(DTypeSig false "toolTextFields" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "toolTextFields" ((PVar "text") (PVar "isErr")) (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr")))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_check: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "toolArgError") (EBinOp "++" (ELit (LString "medaka_check: error: ")) (EVar "m")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None"))) (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (ELit (LString ""))) (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "fieldSymbol" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "fieldSymbol" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "symbol"))) (EVar "args")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "lineTextAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lineTextAt" ((PVar "src") (PVar "line")) (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EVar "src")) (EVar "line")))
(DTypeSig false "lineTextAtIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lineTextAtIndexed" ((PVar "index") (PVar "src") (PVar "line")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "start")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EApp (EApp (EApp (EVar "lineTextEnd") (EApp (EVar "stringToChars") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (EVar "start"))) (EVar "src")))) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0)))))
(DTypeSig false "lineTextEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineTextEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\r")))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identTokenRe" (TyCon "Regex"))
(DFunDef false "identTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "[A-Za-z0-9_']+"))))
(DTypeSig false "identifiersInLine" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identifiersInLine" ((PVar "text")) (EApp (EApp (EMethodRef "map") (EApp (EVar "identPair") (EApp (EVar "indexSource") (EVar "text")))) (EApp (EApp (EVar "findAll") (EVar "identTokenRe")) (EVar "text"))))
(DTypeSig false "identPair" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Match") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identPair" ((PVar "index") (PVar "m")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EFieldAccess (EVar "m") "start")) (arm (PCon "Some" (PTuple PWild (PVar "col"))) () (ETuple (EFieldAccess (EVar "m") "text") (EVar "col"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "identifier regex returned a non-source boundary"))))))
(DTypeSig false "symbolColsInSource" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "symbolColsInSource" ((PVar "index") (PVar "line") (PVar "text") (PVar "symbol")) (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "start")) () (EApp (EApp (EVar "symbolColsGo") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "identPairAt") (EMethodRef "index")) (EVar "start"))) (EApp (EApp (EVar "findAll") (EVar "identTokenRe")) (EVar "text")))) (EVar "symbol")))))
(DTypeSig false "identPairAt" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "identPairAt" ((PVar "index") (PVar "start") (PVar "m")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EBinOp "+" (EVar "start") (EFieldAccess (EVar "m") "start"))) (arm (PCon "Some" (PTuple PWild (PVar "col"))) () (ETuple (EFieldAccess (EVar "m") "text") (EVar "col"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "identifier regex returned a non-source boundary"))))))
(DTypeSig false "symbolColsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsGo" ((PList) PWild) (EListLit))
(DFunDef false "symbolColsGo" ((PCons (PTuple (PVar "name") (PVar "col")) (PVar "rest")) (PVar "symbol")) (EIf (EBinOp "==" (EVar "name") (EVar "symbol")) (EBinOp "::" (EVar "col") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "describeIdentifiers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "describeIdentifiers" ((PList)) (ELit (LString "(none)")))
(DFunDef false "describeIdentifiers" ((PVar "ids")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "identColDesc")) (EVar "ids"))))
(DTypeSig false "identColDesc" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "identColDesc" ((PVar "pair")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "fst") (EVar "pair")) (ELit (LString " (col ")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "pair"))) (ELit (LString ")")))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based UTF-16 column. Alternative to 'symbol' — provide exactly one."))))))) (ETuple (ELit (LString "symbol")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EMethodRef "index")) (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'"))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EApp (EApp (EVar "symbolColsInSource") (EMethodRef "index")) (EVar "line")) (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "' — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText")))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PVar "cols") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtManyCols") (EMethodRef "index")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols"))))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "typeAtOneCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "typeAtOneCol" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EApp (EVar "typeAtMissNote") (EVar "src")) (EVar "line")) (EVar "col"))) (EVar "False")))))
(DTypeSig false "typeAtMissNote" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "typeAtMissNote" ((PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString " — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))
(DTypeSig false "typeAtManyCols" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Json")))))))))))
(DFunDef false "typeAtManyCols" ((PVar "index") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EBlock (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "'")) (EVar "symbol") (ELit (LString "' is ambiguous on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " — ")) (EApp (EVar "intToString") (EApp (EMethodRef "length") (EVar "cols"))) (ELit (LString " matches:"))))) (DoLet false false (PVar "answers") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPointsWithIndex") (EMethodRef "index")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))) (DoLet false false (PVar "bodies") (EApp (EApp (EApp (EVar "zipWith") (EVar "typeAtColLine")) (EVar "cols")) (EVar "answers"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "header") (EVar "bodies")))) (EVar "False")))))
(DTypeSig false "typeAtColLine" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "typeAtColLine" ((PVar "col") (PCon "Some" (PVar "ty"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": ")) (EVar "ty"))))
(DFunDef false "typeAtColLine" ((PVar "col") (PCon "None")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": no symbol")))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "reasonName" (TyFun (TyCon "InvalidReason") (TyCon "String")))
(DFunDef false "reasonName" ((PCon "InvalidDeclaration")) (ELit (LString "invalidDeclaration")))
(DFunDef false "reasonName" ((PCon "TerminalLexError")) (ELit (LString "terminalLexError")))
(DFunDef false "reasonName" ((PCon "UnclosedDelimiter")) (ELit (LString "unclosedDelimiter")))
(DFunDef false "reasonName" ((PCon "MismatchedDelimiter")) (ELit (LString "mismatchedDelimiter")))
(DFunDef false "reasonName" ((PCon "UntrustedBoundary")) (ELit (LString "untrustedBoundary")))
(DFunDef false "reasonName" ((PCon "RecoveryBudget")) (ELit (LString "recoveryBudget")))
(DTypeSig false "stopName" (TyFun (TyCon "RecoveryStop") (TyCon "String")))
(DFunDef false "stopName" ((PCon "ReachedEnd")) (ELit (LString "reachedEnd")))
(DFunDef false "stopName" ((PCon "StoppedLexically")) (ELit (LString "stoppedLexically")))
(DFunDef false "stopName" ((PCon "StoppedDelimiter")) (ELit (LString "stoppedDelimiter")))
(DFunDef false "stopName" ((PCon "StoppedBoundary")) (ELit (LString "stoppedBoundary")))
(DFunDef false "stopName" ((PCon "ExhaustedBudget")) (ELit (LString "exhaustedBudget")))
(DTypeSig false "regionPosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "regionPosition" ((PVar "index") (PVar "off")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "off")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "symbolsResult" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "revision") (EApp (EApp (EApp (EApp (EVar "SourceRevision") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "None")) (ELit (LInt 0))) (EVar "src"))) (DoLet false false (PVar "syntax") (EApp (EVar "parseSnapshotSyntax") (EVar "revision"))) (DoLet false false (PVar "result") (EApp (EVar "snapshotSyntaxResult") (EVar "syntax"))) (DoLet false false (PTuple (PVar "completeness") (PVar "stop")) (EMatch (EApp (EVar "recoveredCompleteness") (EVar "result")) (arm (PCon "Complete") () (ETuple (ELit (LString "complete")) (EVar "JNull"))) (arm (PCon "Partial" (PVar "why")) () (ETuple (ELit (LString "partial")) (EApp (EVar "JString") (EApp (EVar "stopName") (EVar "why"))))))) (DoLet false false (PTuple (PVar "regions") (PVar "diagnostics")) (EMatch (EApp (EVar "snapshotSyntaxSnapshot") (EVar "syntax")) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EVar "sourceEndUtf16Position") (EVar "src"))) (DoExpr (ETuple (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (ELit (LInt 0)))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (ELit (LInt 0))))))) (ETuple (ELit (LString "end")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (ELit (LString "recoveryBudget"))))))) (EListLit))))) (arm (PCon "Some" (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index"))) () (ETuple (EApp (EApp (EMethodRef "map") (ELam ((PVar "region")) (EMatch (EApp (EVar "invalidExtent") (EVar "region")) (arm (PCon "SourceExtent" (PVar "start") (PVar "end")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "regionPosition") (EMethodRef "index")) (EVar "start"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "regionPosition") (EMethodRef "index")) (EVar "end"))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (EApp (EVar "reasonName") (EApp (EVar "invalidReason") (EVar "region"))))))))))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EMethodRef "index")) (EVar "JNull")) (EApp (EApp (EVar "parseDiagnosticToDiag") (EVar "path")) (EVar "d"))))) (EApp (EVar "recoveredDiagnostics") (EVar "result"))))))) (DoLet false false (PVar "metadata") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "origin")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "version")) (EVar "JNull")) (ETuple (ELit (LString "generation")) (EApp (EVar "JInt") (ELit (LInt 0))))))) (ETuple (ELit (LString "completeness")) (EApp (EVar "JString") (EVar "completeness"))) (ETuple (ELit (LString "stop")) (EVar "stop")) (ETuple (ELit (LString "invalidRegions")) (EApp (EVar "jArray") (EVar "regions"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diagnostics")))))) (DoExpr (EMatch (EApp (EApp (EVar "symbolsFromRecovered") (EVar "revision")) (EVar "syntax")) (arm (PCon "Err" PWild) () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: snapshot mismatch")))) (arm (PCon "Ok" (PVar "symbols")) () (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "toolTextFields") (EApp (EVar "stringify") (EApp (EVar "jArray") (EVar "symbols")))) (EVar "False")) (EListLit (ETuple (ELit (LString "structuredContent")) (EVar "metadata"))))))))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "symbolsResult") (EVar "path")) (EVar "src")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EVar "medakaTypeAtSchema"))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "definitionAtCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "definitionAtCol" ((PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))) (arm (PCon "JNull") () (EApp (EApp (EApp (EVar "definitionMissNote") (EVar "line")) (EApp (EVar "Some") (EVar "col"))) (EVar "src"))) (arm (PVar "hit") () (EVar "hit"))))
(DTypeSig false "definitionMissNote" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "definitionMissNote" ((PVar "line") (PVar "maybeCol") (PVar "src")) (EBlock (DoLet false false (PVar "posDesc") (EMatch (EVar "maybeCol") (arm (PCon "Some" (PVar "col")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line"))))))) (DoExpr (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at ")) (EVar "posDesc")))))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at ")) (EVar "posDesc"))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))))))
(DTypeSig false "identPairJson" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "Json")))
(DFunDef false "identPairJson" ((PVar "pair")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "fst") (EVar "pair")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "snd") (EVar "pair")))))))
(DTypeSig false "definitionManyCols" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Json"))))))))
(DFunDef false "definitionManyCols" ((PVar "index") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "ambiguous")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "symbol")) (EApp (EVar "JString") (EVar "symbol"))) (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "zipWith") (EVar "definitionOneMatch")) (EVar "cols")) (EApp (EApp (EApp (EApp (EApp (EVar "definitionResultsWithIndex") (EMethodRef "index")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))))))))
(DTypeSig false "definitionOneMatch" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "definitionOneMatch" ((PVar "col") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EVar "col"))) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lineTextAtIndexed") (EMethodRef "index")) (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'")))))))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EApp (EApp (EVar "symbolColsInSource") (EMethodRef "index")) (EVar "line")) (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "'")))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PVar "cols") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionManyCols") (EMethodRef "index")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols")))) (EVar "False"))))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "medakaReferencesSchema" (TyCon "Json"))
(DFunDef false "medakaReferencesSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based UTF-16 column of the position (first column is 0)."))))))) (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Include the symbol's own declaration site in the result. Default true.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "referencesParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Json")))))
(DFunDef false "referencesParams" ((PVar "line") (PVar "col") (PVar "includeDecl")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "context")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "JBool") (EVar "includeDecl")))))))))
(DTypeSig false "runReferencesTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runReferencesTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_references: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "includeDecl") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "includeDeclaration"))) (EVar "True")) (EVar "args"))) (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EApp (EApp (EApp (EVar "referencesParams") (EVar "line")) (EVar "col")) (EVar "includeDecl"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EVar "result"))) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EMethodRef "index")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "offset")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString ", col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "None") () (ELit (LString "unknown position"))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" (PVar "formatted")) () (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
(DTypeSig false "runFmtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runFmtTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "check"))) (EVar "False")) (EVar "args"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src")))))))
(DTypeSig false "medakaLintSchema" (TyCon "Json"))
(DFunDef false "medakaLintSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "paths")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "array")))) (ETuple (ELit (LString "items")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string"))))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Paths to .mdk files to lint."))))))) (ETuple (ELit (LString "deny")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to promote to error severity (mirrors --deny)."))))))) (ETuple (ELit (LString "only")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only)."))))))) (ETuple (ELit (LString "disable")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to suppress (mirrors --disable).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "paths")))))))))
(DTypeSig false "jsonArrToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "jsonArrToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonArrToListGo" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "jsonArrToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pathsArg" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pathsArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "paths"))) (EVar "args")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asArray") (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "arr")) () (EApp (EVar "allJsonStrings") (EApp (EVar "jsonArrToList") (EVar "arr"))))))))
(DTypeSig false "allJsonStrings" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allJsonStrings" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allJsonStrings" ((PCons (PVar "j") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "asString") (EVar "j")) (EApp (EVar "allJsonStrings") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "s")) (PCon "Some" (PVar "ss"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "s") (EVar "ss")))) (arm PWild () (EVar "None"))))
(DTypeSig false "lintNameListArg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNameListArg" ((PVar "key") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (EVar "key")) (EVar "args")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PLit (LString ""))) () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "splitLintNames") (EVar "s")))))
(DTypeSig true "lintPathsToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "lintPathsToDiagQuads" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "paths")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny"))) (EVar "paths")))
(DTypeSig true "crossFileMcpFindings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "crossFileMcpFindings" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "quads")) (EBlock (DoLet false false (PVar "parsedTriples") (EApp (EApp (EMethodRef "map") (EVar "quadToParseTriple")) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "only")) (EVar "disable")) (EVar "parsedTriples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "suppressed")))))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "indexResult") (EIf (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EVar "disable")) (EVar "buildStdlibIndexResult") (EApp (EVar "Ok") (EVar "emptyStdlibIndex")))) (DoExpr (EMatch (EVar "indexResult") (arm (PCon "Err" (PRec "StdlibIndexError" ((rf "path" None) (rf "source" None) (rf "diagnostic" None)) false)) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "path") (EVar "source") (EListLit (EVar "diagnostic")))))) (EVar "True"))) (arm (PCon "Ok" (PVar "idx")) () (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagQuads") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EVar "crossFileMcpFindings") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "cross")) (EVar "triples"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "merged"))) (EApp (EVar "anyTripleHasErr") (EVar "merged"))))))))))))
(DTypeSig false "mcpTestDefaultEngines" (TyApp (TyCon "List") (TyCon "Engine")))
(DFunDef false "mcpTestDefaultEngines" () (EListLit (EVar "EngNative")))
(DTypeSig false "mcpTestEngineHasNative" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "Bool")))
(DFunDef false "mcpTestEngineHasNative" ((PList)) (EVar "False"))
(DFunDef false "mcpTestEngineHasNative" ((PCons (PCon "EngNative") PWild)) (EVar "True"))
(DFunDef false "mcpTestEngineHasNative" ((PCons PWild (PVar "rest"))) (EApp (EVar "mcpTestEngineHasNative") (EVar "rest")))
(DTypeSig false "mcpTestEnginesArg" (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "mcpTestEnginesArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "engine"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "mcpTestDefaultEngines"))) (arm (PCon "Some" (PCon "JString" (PLit (LString "native")))) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PCon "Some" (PCon "JString" (PLit (LString "eval")))) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp")))) (arm (PCon "Some" (PCon "JString" (PVar "other"))) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka_test: unknown engine '")) (EApp (EMethodRef "display") (EVar "other"))) (ELit (LString "' — 'engine' must be \"native\" (default) or \"eval\""))))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "medaka_test: 'engine' must be a string, \"native\" (default) or \"eval\""))))))
(DTypeSig false "mcpTestCaveat" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "mcpTestCaveat" ((PVar "engines")) (EIf (EApp (EVar "mcpTestEngineHasNative") (EVar "engines")) (ELit (LString "Results are under the NATIVE backend, the same engine `medaka test` defaults to, for both doctests and property tests. If the native build is unavailable (no clang), engine \"eval\" asks for the interpreter instead.")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "⚠️ RESULTS ARE UNDER THE INTERPRETER (")) (EApp (EMethodRef "display") (EApp (EVar "engineName") (EVar "EngInterp")))) (ELit (LString "), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mcpTestDescription" (TyCon "String"))
(DFunDef false "mcpTestDescription" () (ELit (LString "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. Runs under the native backend by default, like `medaka test` (one clang build per call); optional `engine` \"eval\" runs the interpreter instead. Bare `test \"…\"` decls are NOT run here.")))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run."))))))) (ETuple (ELit (LString "engine")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "enum")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "native"))) (EApp (EVar "JString") (ELit (LString "eval")))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Execution engine for doctests and property tests. Default \"native\" (what `medaka test` defaults to); \"eval\" runs the interpreter.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EBinOp "-" (EApp (EVar "exampleLine") (EVar "ex")) (ELit (LInt 1))))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultJsonFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "GradedProp") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "row")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "propResultEngine") (EVar "p")))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedPropStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedPropRawStatus") (EVar "row")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EApp (EVar "propResultFailureKind") (EVar "p")))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EApp (EVar "propResultSeed") (EVar "p")))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EApp (EVar "propResultCases") (EVar "p"))))) (EApp (EVar "issueField") (EApp (EVar "gradedPropIssue") (EVar "row")))) (EApp (EVar "pinField") (EApp (EVar "gradedPropPinDetail") (EVar "row"))))))))
(DTypeSig false "issueField" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "issueField" ((PCon "None")) (EListLit))
(DFunDef false "issueField" ((PCon "Some" (PVar "issue"))) (EListLit (ETuple (ELit (LString "issue")) (EApp (EVar "JInt") (EVar "issue")))))
(DTypeSig false "pinField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "pinField" ((PCon "None")) (EListLit))
(DFunDef false "pinField" ((PCon "Some" (PVar "detail"))) (EListLit (ETuple (ELit (LString "pin")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EApp (EVar "gradedPropRaw") (EVar "p"))) (EApp (EVar "gradedPropPassed") (EVar "p"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedPropPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "primaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "primaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "primaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "testReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))))
(DFunDef false "testReportOk" ((PVar "typeError") (PVar "runs") (PVar "props")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "allDoctestRunsOk") (EVar "runs"))) (EApp (EVar "allPropsPass") (EVar "props"))))
(DTypeSig false "allDoctestRunsOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "Bool")))
(DFunDef false "allDoctestRunsOk" ((PList)) (EVar "True"))
(DFunDef false "allDoctestRunsOk" ((PCons (PTuple PWild (PVar "run")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "allDoctestRunsOk") (EVar "rest"))))
(DTypeSig false "doctestRunEngineNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "Engine"))))
(DFunDef false "doctestRunEngineNames" ((PList)) (EListLit))
(DFunDef false "doctestRunEngineNames" ((PCons (PTuple (PVar "e") PWild) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "doctestRunEngineNames") (EVar "rest"))))
(DTypeSig false "primaryEngineName" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "primaryEngineName" ((PList)) (ELit (LString "unknown")))
(DFunDef false "primaryEngineName" ((PCons (PVar "e") PWild)) (EApp (EVar "engineName") (EVar "e")))
(DTypeSig false "typeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "typeErrorField" ((PCon "Some" (PCon "TestSetupError" (PVar "errText")))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DFunDef false "typeErrorField" ((PCon "Some" (PCon "TestDiagnosticError" (PVar "triples")))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EDictApp "flatMap") (EVar "testDiagnosticMessages")) (EVar "triples"))))) (ETuple (ELit (LString "typeDiagnostics")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "testDiagnosticFile")) (EVar "triples"))))))
(DTypeSig false "testDiagnosticMessages" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testDiagnosticMessages" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EMethodRef "map") (ELam ((PCon "Diag" PWild PWild (PVar "message") PWild PWild PWild)) (EVar "message"))) (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "testDiagnosticFile" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "testDiagnosticFile" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig false "typecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "typecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testDeclsSkippedField" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))
(DFunDef false "testDeclsSkippedField" () (EListLit (ETuple (ELit (LString "testDeclsSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "Option") (TyCon "TestReportError")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyCon "Bool") (TyCon "Json"))))))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "requested") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "engines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "doctestRunEngineNames") (EVar "runs")) (EVar "requested"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "primaryEngineName") (EVar "engines")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "mcpTestCaveat") (EVar "engines"))))) (EApp (EVar "typeErrorField") (EVar "typeError"))) (EApp (EVar "typecheckSkippedField") (EVar "typecheckSkipped"))) (EVar "testDeclsSkippedField")) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "knownRed")) (EApp (EVar "JInt") (EApp (EVar "knownRedCountProps") (EVar "props")))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "mcpTestEnginesArg") (EVar "args")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "toolArgError") (EVar "msg"))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "err")) () (EBlock (DoLet false false (PVar "failure") (EApp (EVar "Some") (EApp (EVar "TestDiagnosticError") (EListLit (ETuple (EVar "path") (EVar "tsrc") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "err")))))))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "engines")) (EVar "failure")) (EListLit)) (EListLit)) (EVar "False")))) (EVar "True"))))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "_testResults") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestGradedReportParts") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EApp (EVar "desugar") (EVar "decls"))) (EVar "stdlibDir")) (ELit (LInt 100))) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "engines")) (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "typecheckSkipped")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params") (PVar "stalenessCheck")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "logMcpCall") (ELit (LString "tools/call"))) (EVar "name")) (EApp (EVar "stringify") (EVar "args")))) (DoLet false false PWild (EApp (EVar "selectToolProfile") (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EVar "args")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EBlock (DoLet false false (PVar "augmented") (EApp (EApp (EVar "attachStaleness") (EVar "stalenessCheck")) (EVar "result"))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "augmented"))))))))))))
(DTypeSig false "selectToolProfile" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "selectToolProfile" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "path"))) (DoExpr (ELit LUnit)))) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None")))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EVar "unit") (EApp (EApp (EApp (EVar "logMcpCall") (EVar "meth")) (ELit (LString ""))) (ELit (LString ""))))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "get") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))) (EVar "serverVersion")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EVar "stalenessCheck")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg")) (EVar "stalenessCheck")) (EVar "serverVersion"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw")) (EVar "stalenessCheck")) (EVar "serverVersion"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))
