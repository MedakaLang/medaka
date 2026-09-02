# META
source_lines=1501
stages=DESUGAR,MARK
# SOURCE
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
-- and drags no new type surface.  A few tiny helpers are instead COPIED from
-- lsp.mdk (responseMsg + the fieldOr/fieldStr accessors): lsp.mdk does not export
-- them, and copying keeps the cross-module surface small (no edit to lsp.mdk, no
-- new shared type/instance surface).  Each copy carries its own scoped
-- rule-duplicate-body disable.  `errorMsg` is ORIGINAL to this file — LSP never
-- emits a JSON-RPC error object over its transport, so there is nothing to copy.

import json.{
  Json,
  JNull,
  JInt,
  JString,
  JBool,
  JObject,
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
import driver.diagnostics.{
  checkJsonSingle,
  checkJsonFile,
  cjAllToJson,
  diagIsError,
  Diag,
}
import tools.lsp.{
  typeAtPoint,
  documentSymbols,
  definitionResult,
  referencesResult,
  emptyDocs,
  docsPut,
  uriOfPath,
}
import frontend.parser.{
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import tools.fmt.{formatSource}
import tools.lint.{
  lintFileDiagTriple,
  splitLintNames,
  buildStdlibIndex,
  StdlibIndex,
}
import tools.test_cmd.{runTestReport}
import tools.doctest.{
  Example,
  ExResult(..),
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
  PropResult,
  propResultName,
  propResultPassed,
  propResultDetail,
}
import support.char.{isIdentChar}
import support.util.{joinWith}

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

-- ── JSON-RPC envelopes (copied from lsp.mdk; see header) ─────────────────────

-- A JSON-RPC success envelope: { jsonrpc, id, result }.
responseMsg : Json -> Json -> Json
-- Intentional cross-file duplicate of lsp.mdk's responseMsg; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
responseMsg idJson result =
  jObject [("jsonrpc", JString "2.0"), ("id", idJson), ("result", result)]

-- A JSON-RPC error envelope: { jsonrpc, id, error: { code, message } }.
errorMsg : Json -> Int -> String -> Json
errorMsg idJson code message = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("id", idJson),
    ("error", jObject [("code", JInt code), ("message", JString message)]),
  ]

-- ── field accessors (copied from lsp.mdk) ────────────────────────────────────

fieldOr : String -> Json -> Json
-- Intentional cross-file duplicate of lsp.mdk's fieldOr; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
fieldOr key j = match get key j
  Some v => v
  None => JNull

fieldStr : String -> Json -> Option String
-- Intentional cross-file duplicate of lsp.mdk's fieldStr; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
fieldStr key j = match get key j
  Some v => asString v
  None => None

methodOf : Json -> Option String
methodOf msg = fieldStr "method" msg

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
-- this binary was built from.  Fresh/unknown ⇒ `result` is returned
-- UNCHANGED — zero added tokens in the common case.
attachStaleness : (Unit -> <IO> Option String) -> Json -> <IO> Json
attachStaleness stalenessCheck result = match stalenessCheck ()
  None => result
  Some compilerDir => jsonObjectAppend "staleBinary" (JString (stringConcat [
    "this server's binary predates the compiler source at ",
    compilerDir,
    " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).",
  ])) result

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
initializeResultFor protocolVersion serverVersion = jObject
  [
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
  | McpTool String String Json (String -> String -> String -> Json -> <IO> Json)
--        name   desc   schema  handler(runtimeSrc coreSrc stdlibDir args)

-- Descriptions are DIRECTIVE (gopls/Serena convention), not just descriptive:
-- each says WHEN this tool beats grep/Bash, not only what it computes — the
-- model's default is to reach for Grep/Bash even with a working tool present
-- (anthropics/claude-code#32599; #847). Kept short on purpose — paid for in
-- every agent's context window on every session.
mcpTools : List McpTool
mcpTools = [
  McpTool "medaka_check" "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns the same structured JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`." medakaCheckSchema runCheckTool,
  McpTool "medaka_type_at" "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result." medakaTypeAtSchema runTypeAtTool,
  McpTool "medaka_symbols" "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. A parse failure returns a distinct `{\"parseError\":true,\"line\",\"col\",\"message\"}` isError, never a silently-empty list." medakaSymbolsSchema runSymbolsTool,
  McpTool "medaka_definition" "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result." medakaDefinitionSchema runDefinitionTool,
  McpTool "medaka_references" "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line`/`col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies." medakaReferencesSchema runReferencesTool,
  McpTool "medaka_fmt" "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)." medakaFmtSchema runFmtTool,
  McpTool "medaka_lint" "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`." medakaLintSchema runLintTool,
  McpTool "medaka_test" mcpTestDescription medakaTestSchema runTestTool,
]

-- The `tools/list` descriptor for one tool: { name, description, inputSchema }.
toolDescriptor : McpTool -> Json
toolDescriptor (McpTool name desc schema _) = jObject
  [
    ("name", JString name),
    ("description", JString desc),
    ("inputSchema", schema),
  ]

-- Dispatch a tools/call by tool name against `mcpTools`.  `None` ⇒ no such tool
-- (caller emits JSON-RPC -32601).  `Some result` ⇒ the tool's result Json.
callTool : String -> String -> String -> String -> Json -> <IO> Option Json
callTool runtimeSrc coreSrc stdlibDir name args = map
  ((McpTool _ _ _ handler) => handler runtimeSrc coreSrc stdlibDir args)
  (lookupTool name mcpTools)

lookupTool : String -> List McpTool -> Option McpTool
lookupTool _ [] = None
lookupTool name (t::ts) = match t
  McpTool n _ _ _ => if n == name then Some t else lookupTool name ts

-- ── medaka_check tool ─────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text).
medakaCheckSchema : Json
medakaCheckSchema = jObject
  [
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
toolTextResult text isErr = jObject
  [
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
runCheckTool runtimeSrc coreSrc stdlibDir args = match (fieldStr "file" args, fieldStr "source" args)
  (Some _, Some _) => toolArgError "medaka_check: provide exactly one of 'file' or 'source', not both"
  (None, None) => toolArgError "medaka_check: missing argument — provide exactly one of 'file' or 'source'"
  (Some path, None) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_check: cannot read file '", path, "': ", e])
    Ok _ =>
      let (json, hasErr) = checkJsonFile False runtimeSrc coreSrc path stdlibDir
      toolTextResult json hasErr
  (None, Some src) =>
    let (json, hasErr) = checkJsonSingle "" False runtimeSrc coreSrc syntheticSourceName src
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

-- The raw text of 0-based `line` of `src` (no line terminator), or None if
-- the file has no such line.  One left-to-right pass over the char array:
-- walk past `line` newlines to find the start, then scan on to that line's
-- own terminating '\n' (or EOF for an unterminated final line).
lineTextAt : String -> Int -> Option String
lineTextAt src line
  | line < 0 = None
  | otherwise = lineTextGo (stringToChars src) src (stringLength src) 0 0 line

lineTextGo : Array Char -> String -> Int -> Int -> Int -> Int -> Option String
lineTextGo arr src len i curLine target
  | curLine == target = Some (stringSlice i (lineTextEnd arr len i) src)
  | i >= len = None
  | arrayGetUnsafe i arr == '\n' =
    lineTextGo arr src len (i + 1) (curLine + 1) target
  | otherwise = lineTextGo arr src len (i + 1) curLine target

lineTextEnd : Array Char -> Int -> Int -> Int
lineTextEnd arr len i
  | i >= len = len
  | arrayGetUnsafe i arr == '\n' = i
  | otherwise = lineTextEnd arr len (i + 1)

-- Every identifier token on `text` (support.char.isIdentChar runs), as
-- (name, 0-based column) pairs in left-to-right order.
identifiersInLine : String -> List (String, Int)
identifiersInLine text =
  identsGo (stringToChars text) text (stringLength text) 0

identsGo : Array Char -> String -> Int -> Int -> List (String, Int)
identsGo arr text len i
  | i >= len = []
  | isIdentChar (arrayGetUnsafe i arr) =
    let e = identsRunEnd arr len (i + 1)
    (stringSlice i e text, i) :: identsGo arr text len e
  | otherwise = identsGo arr text len (i + 1)

identsRunEnd : Array Char -> Int -> Int -> Int
identsRunEnd arr len i
  | i >= len = len
  | isIdentChar (arrayGetUnsafe i arr) = identsRunEnd arr len (i + 1)
  | otherwise = i

-- Columns where `symbol` appears as a WHOLE identifier token on `text`
-- (exact match, not substring — "x" does not match "xs").
symbolColsOnLine : String -> String -> List Int
symbolColsOnLine text symbol = symbolColsGo (identifiersInLine text) symbol

symbolColsGo : List (String, Int) -> String -> List Int
symbolColsGo [] _ = []
symbolColsGo ((name, col)::rest) symbol
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
medakaTypeAtSchema = jObject
  [
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
              JString "0-based column (LSP-style). Alternative to 'symbol' — provide exactly one.",
            ),
          ],
        ),
        (
          "symbol",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.",
            ),
          ],
        ),
      ],
    ),
    ("required", jArray [JString "file", JString "line"]),
  ]

-- medaka_type_at handler: read `file` from disk and infer the type at `line`
-- plus either `col` (unchanged) or `symbol` (#849 — resolved to a column by
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
runTypeAtTool runtimeSrc coreSrc _stdlibDir args = match (fieldStr "file" args, fieldInt "line" args)
  (Some path, Some line) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_type_at: cannot read file '", path, "': ", e])
    Ok src => match (fieldInt "col" args, fieldSymbol args)
      (Some _, Some _) => toolArgError "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both"
      (None, None) => toolArgError "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)"
      (Some col, None) => typeAtOneCol runtimeSrc coreSrc path src line col
      (None, Some symbol) => match lineTextAt src line
        None => toolTextResult (stringConcat [
          "medaka_type_at: line ",
          intToString line,
          " does not exist in '",
          path,
          "'",
        ]) False
        Some lineText => match symbolColsOnLine lineText symbol
          [] => toolTextResult (stringConcat [
            "no identifier named '",
            symbol,
            "' on line ",
            intToString line,
            " of '",
            path,
            "' — identifiers on this line: ",
            describeIdentifiers (identifiersInLine lineText),
          ]) False
          [col] => typeAtOneCol runtimeSrc coreSrc path src line col
          cols => typeAtManyCols runtimeSrc coreSrc path src line symbol cols
  _ => toolArgError "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"

-- Resolve one (line, col) via the existing stateless hover harness
-- (tools.lsp.typeAtPoint).  A miss is enriched with the identifiers actually
-- on that line (#849) — applies to BOTH addressing modes, since a col-mode
-- miss is exactly the ambiguity #849 reports.
typeAtOneCol : String -> String -> String -> String -> Int -> Int -> <IO> Json
typeAtOneCol runtimeSrc coreSrc path src line col = match typeAtPoint runtimeSrc coreSrc path src line col
  Some ty => toolTextResult ty False
  None => toolTextResult (typeAtMissNote src line col) False

typeAtMissNote : String -> Int -> Int -> String
typeAtMissNote src line col = match lineTextAt src line
  None => stringConcat ["no symbol at line ", intToString line, " col ", intToString col]
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
typeAtManyCols : String -> String -> String -> String -> Int -> String -> List Int -> <IO> Json
typeAtManyCols runtimeSrc coreSrc path src line symbol cols =
  let header = stringConcat [
    "'",
    symbol,
    "' is ambiguous on line ",
    intToString line,
    " — ",
    intToString (length cols),
    " matches:",
  ]
  let bodies = typeAtColLines runtimeSrc coreSrc path src line cols
  toolTextResult (joinWith "\n" (header::bodies)) False

typeAtColLines : String -> String -> String -> String -> Int -> List Int -> <IO> List String
typeAtColLines _runtimeSrc _coreSrc _path _src _line [] = []
typeAtColLines runtimeSrc coreSrc path src line (col::rest) =
  let here = match typeAtPoint runtimeSrc coreSrc path src line col
    Some ty => stringConcat ["  col ", intToString col, ": ", ty]
    None => stringConcat ["  col ", intToString col, ": no symbol"]
  here :: typeAtColLines runtimeSrc coreSrc path src line rest

-- ── medaka_symbols tool ───────────────────────────────────────────────────────

-- inputSchema: `file` (path), required.
medakaSymbolsSchema : Json
medakaSymbolsSchema = jObject
  [
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
        )
      ],
    ),
    ("required", jArray [JString "file"]),
  ]

-- Turn resolved source into a symbols result.  Parse FIRST (via parseResult, the
-- same located-diagnostic path medaka_fmt uses) so a genuinely empty/no-decl file
-- (empty `[]`, isError:false) is DISTINGUISHABLE from one that failed to parse
-- (#300 part 1): a parse failure yields a distinct structured note
-- `{"parseError":true, line, col, message}` with isError:true, instead of the same
-- `[]` an empty file returns.  documentSymbols itself is parse-only and returns
-- `[]` on unparseable input, which is exactly the ambiguity we resolve here.
symbolsResult : String -> Json
symbolsResult src = match parseResult src
  Err e => toolTextResult (stringify (jObject [
    ("parseError", JBool True),
    ("line", JInt (parseErrorLine e)),
    ("col", JInt (parseErrorCol e)),
    ("message", JString (parseErrorMessage e)),
  ])) True
  Ok _ => toolTextResult (stringify (jArray (documentSymbols src))) False

-- medaka_symbols handler: read `file` from disk and return its top-level decl
-- symbols (tools.lsp.documentSymbols), serialized as a JSON array in a text
-- content block.  Parse-only (no typecheck) — never errors on an ill-typed
-- file, only on a missing/unreadable one.  A file that fails to PARSE returns a
-- distinct isError parseError note (symbolsResult), NOT the empty `[]` an empty
-- file returns — so a caller can tell 'no decls' from 'parser bailed' (#300 p1).
runSymbolsTool : String -> String -> String -> Json -> <IO> Json
runSymbolsTool _runtimeSrc _coreSrc _stdlibDir args = match fieldStr "file" args
  None => toolArgError "medaka_symbols: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e => toolArgError (stringConcat ["medaka_symbols: cannot read file '", path, "': ", e])
    Ok src => symbolsResult src

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
positionParams line col = jObject
  [("position", jObject [("line", JInt line), ("character", JInt col)])]

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
definitionAtCol path src line col = match definitionResult path src (positionParams line col)
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
definitionManyCols : String -> String -> Int -> String -> List Int -> Json
definitionManyCols path src line symbol cols = jObject
  [
    ("ambiguous", JBool True),
    ("symbol", JString symbol),
    ("matches", jArray (map (definitionOneMatch path src line) cols)),
  ]

definitionOneMatch : String -> String -> Int -> Int -> Json
definitionOneMatch path src line col = jObject
  [
    ("col", JInt col),
    ("result", definitionResult path src (positionParams line col)),
  ]

-- medaka_definition handler: read `file` from disk and resolve the
-- identifier at `line` plus either `col` (unchanged) or `symbol` (#849 —
-- resolved to a column by searching the line's own text).  `uri` is passed
-- as the caller's own `file` string, UNCHANGED (no `uriOfPath`/`file://`
-- wrapping) — a relative request path stays relative in the echoed result,
-- so a transcript golden over it is path-stable.  A missing file or bad
-- arguments ⇒ an isError result (the arguments were malformed, not the
-- call); every other outcome (hit, miss, ambiguous, out-of-range line) is a
-- CLEAN, ACTIONABLE result, never a crash.
runDefinitionTool : String -> String -> String -> Json -> <IO> Json
runDefinitionTool _runtimeSrc _coreSrc _stdlibDir args = match (fieldStr "file" args, fieldInt "line" args)
  (Some path, Some line) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_definition: cannot read file '", path, "': ", e])
    Ok src => match (fieldInt "col" args, fieldSymbol args)
      (Some _, Some _) => toolArgError "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both"
      (None, None) => toolArgError "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)"
      (Some col, None) =>
        toolTextResult (stringify (definitionAtCol path src line col)) False
      (None, Some symbol) => match lineTextAt src line
        None => toolTextResult (stringify (jObject [
          ("matches", jArray []),
          (
            "note",
            JString (stringConcat ["line ", intToString line, " does not exist in '", path, "'"]),
          ),
        ])) False
        Some lineText => match symbolColsOnLine lineText symbol
          [] => toolTextResult (stringify (jObject [
            ("matches", jArray []),
            (
              "note",
              JString (stringConcat [
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
          ])) False
          [col] => toolTextResult (stringify (definitionAtCol path src line col)) False
          cols => toolTextResult (stringify (definitionManyCols path src line symbol cols)) False
  _ => toolArgError "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"

-- ── medaka_references tool ───────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`/`col`, the 0-based LSP-style
-- position; optional `includeDeclaration` (boolean, default true, F6).
medakaReferencesSchema : Json
medakaReferencesSchema = jObject
  [
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
              JString "0-based column of the position (LSP-style, first column is 0).",
            ),
          ],
        ),
        (
          "includeDeclaration",
          jObject [
            ("type", JString "boolean"),
            (
              "description",
              JString "Include the symbol's own declaration site in the result. Default true.",
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
referencesParams line col includeDecl = jObject
  [
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
runReferencesTool runtimeSrc coreSrc _stdlibDir args = match (fieldStr "file" args, fieldInt "line" args, fieldInt "col" args)
  (Some path, Some line, Some col) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_references: cannot read file '", path, "': ", e])
    Ok src =>
      let includeDecl = fieldBoolOr "includeDeclaration" True args
      let uri = uriOfPath path
      let docs = docsPut uri src emptyDocs
      let result = referencesResult runtimeSrc coreSrc uri src (referencesParams line col includeDecl) docs
      toolTextResult (stringify result) False
  _ => toolArgError "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"

-- ── medaka_fmt tool ───────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text); optional
-- `check` (boolean, default false — see medakaFmtSchema's own "check" doc).
medakaFmtSchema : Json
medakaFmtSchema = jObject
  [
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
              JString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply.",
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
              JString "If true, report clean/dirty instead of returning the formatted text (default false).",
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

-- Format (or format-check) already-resolved source text.  `formatSource`
-- PANICS on unparseable input (`parseWithPositions`'s documented
-- panic-on-unparseable contract, compiler/frontend/parser.mdk) — a panic here
-- would crash the whole MCP server process, so parseability is checked FIRST,
-- mirroring `formattingEdits`'s `Err _ => []` short-circuit
-- (compiler/tools/lsp.mdk:236-237). Unlike that LSP path — which has a client
-- buffer to silently leave alone — an MCP caller gets an explicit isError
-- result carrying the located parse diagnostic, never a silent no-op.
fmtResult : Bool -> String -> Json
fmtResult check src = match parseResult src
  Err e =>
    let loc = stringConcat [
      "line ",
      intToString (parseErrorLine e),
      ", col ",
      intToString (parseErrorCol e),
    ]
    toolArgError (stringConcat
      ["medaka_fmt: source does not parse (", loc, "): ", parseErrorMessage e])
  Ok _ =>
    let formatted = formatSource src
    if check then
      toolTextResult (stringify (jObject [("clean", JBool (formatted == src))])) False
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
    (Some _, Some _) => toolArgError "medaka_fmt: provide exactly one of 'file' or 'source', not both"
    (None, None) => toolArgError "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'"
    (Some path, None) => match readFile path
      Err e => toolArgError (stringConcat ["medaka_fmt: cannot read file '", path, "': ", e])
      Ok src => fmtResult check src
    (None, Some src) => fmtResult check src

-- ── medaka_lint tool ──────────────────────────────────────────────────────────

-- inputSchema: `paths` (array of file path strings, required) plus the
-- lint CLI's rule-name-list flags as comma-separated strings — `deny`/`only`/
-- `disable` (mirrors --deny/--only/--disable). Report-only (#249): no `--fix`
-- equivalent — a suggesting rule must prove its fix compiles (TOOLING.md /
-- #56) and report-only sidesteps that for v1.
medakaLintSchema : Json
medakaLintSchema = jObject
  [
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
              JString "Comma-separated rule names to promote to error severity (mirrors --deny).",
            ),
          ],
        ),
        (
          "only",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only).",
            ),
          ],
        ),
        (
          "disable",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Comma-separated rule names to suppress (mirrors --disable).",
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
allJsonStrings (j::rest) = match (asString j, allJsonStrings rest)
  (Some s, Some ss) => Some (s::ss)
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

-- Sequence `lintFileDiagTriple` over every target path, in order (same
-- explicit-recursion idiom `medaka_cli.mdk`'s `lintFilesToDiagTriples` uses —
-- `map` over an effectful function is not how this codebase sequences an
-- `<IO>` list traversal).
--
-- `idx` is the stdlib reference index, built ONCE by the caller and threaded:
-- it is the same value for every path in the request, and rebuilding it per
-- path would re-parse the whole stdlib once per target file.
lintPathsToDiagTriples : StdlibIndex -> List String -> List String -> List String -> List String -> <IO> List (String, String, List Diag)
lintPathsToDiagTriples _ _ _ _ [] = []
lintPathsToDiagTriples idx disable only deny (p::rest) =
  lintFileDiagTriple idx disable only deny p ::
    lintPathsToDiagTriples idx disable only deny rest

anyTripleHasErr : List (String, String, List Diag) -> Bool
anyTripleHasErr [] = False
anyTripleHasErr ((_, _, diags)::rest) = anyDiagErr diags || anyTripleHasErr rest

anyDiagErr : List Diag -> Bool
anyDiagErr [] = False
anyDiagErr (d::rest) = diagIsError d || anyDiagErr rest

-- medaka_lint handler: run the lint pipeline (all rules, inline
-- `-- lint-disable-*` suppression, then the `disable`/`only`/`deny` filters)
-- over every path in `paths` and return the SAME `{"files":[...]}` envelope
-- `medaka_check`/`medaka lint --json` emit (via `cjAllToJson`) — one schema
-- across all three surfaces. Each `Finding` becomes a `Diag` via
-- `findingToDiag` (inside `lintFileDiagTriple`), which stamps the lint RULE
-- NAME into the diagnostic's `code`. `isError` is true iff any diagnostic is a
-- hard error (severity 1) — only reachable via `deny` promotion, since every
-- seed rule defaults to SevWarning.
runLintTool : String -> String -> String -> Json -> <IO> Json
runLintTool _runtimeSrc _coreSrc _stdlibDir args = match pathsArg args
  None => toolArgError "medaka_lint: missing or invalid argument — require 'paths' (array of strings)"
  Some paths =>
    let disable = lintNameListArg "disable" args
    let only = lintNameListArg "only" args
    let deny = lintNameListArg "deny" args
    -- once per REQUEST, not per path (see lintPathsToDiagTriples)
    let idx = buildStdlibIndex
    let triples = lintPathsToDiagTriples idx disable only deny paths
    toolTextResult (cjAllToJson triples) (anyTripleHasErr triples)

-- ── medaka_test tool ──────────────────────────────────────────────────────────

-- The engine(s) `medaka_test` actually runs. SINGLE SOURCE OF TRUTH: the tool
-- description (below) and the payload's `engine`/`note` fields
-- (`testReportJson`) are both DERIVED from this list rather than each
-- carrying its own hand-written "eval" literal — three independent hardcodes
-- that would silently start lying together (or, worse, drift apart from one
-- another) the day this tool gains a native arm.  Today it is interpreter-only
-- (#81 Stage 3 wires `--native` into the human `medaka test` CLI only, not
-- this tool), so the list is `[EngInterp]`.
mcpTestEngines : List Engine
mcpTestEngines = [EngInterp]

mcpTestEngineHasNative : List Engine -> Bool
mcpTestEngineHasNative [] = False
mcpTestEngineHasNative (EngNative::_) = True
mcpTestEngineHasNative (_::rest) = mcpTestEngineHasNative rest

-- The caveat sentence, derived from `engines`: interpreter-only gets the
-- original #81 warning; a list that includes the native engine gets an
-- honest statement instead of a now-false "results are eval-only" claim.
mcpTestCaveat : List Engine -> String
mcpTestCaveat engines
  | mcpTestEngineHasNative engines = "Results include the NATIVE backend engine (not just the interpreter) — a native-only miscompile is observed here."
  | otherwise = "⚠️ RESULTS ARE UNDER THE INTERPRETER (\{engineName EngInterp}), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."

mcpTestDescription : String
mcpTestDescription = "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. \{mcpTestCaveat mcpTestEngines} Bare `test \"…\"` decls are NOT run here."

-- inputSchema: `file` (path), required.
medakaTestSchema : Json
medakaTestSchema = jObject
  [
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
              JString "Path to the .mdk file whose doctests (and property tests, if any) to run.",
            ),
          ],
        )
      ],
    ),
    ("required", jArray [JString "file"]),
  ]

-- The per-example fields, keyed by outcome.  A smoke example (no expected line)
-- that evaluated cleanly is `Pass` with no expected/actual; a `Fail` carries
-- both; an `Errored` carries the message under `detail`.
exResultFields : ExResult -> List (String, Json)
exResultFields Pass = [("status", JString "pass")]
exResultFields (Fail expected actual) = [
  ("status", JString "fail"),
  ("expected", JString expected),
  ("actual", JString actual),
]
exResultFields (Errored msg) =
  [("status", JString "error"), ("detail", JString msg)]

exampleJson : (Example, ExResult) -> Json
exampleJson (ex, res) =
  jObject
    ([("line", JInt (exampleLine ex)), ("input", JString (exampleInput ex))] ++ exResultFields res)

doctestsJson : RunResult -> Json
doctestsJson run = jObject
  [
    ("total", JInt (runPassed run + runFailed run + runErrors run)),
    ("passed", JInt (runPassed run)),
    ("failed", JInt (runFailed run)),
    ("errors", JInt (runErrors run)),
    ("examples", jArray (map exampleJson (runDetails run))),
  ]

propJson : PropResult -> Json
-- Structurally identical to medaka_cli.mdk's `cliTestReportJson`-side
-- `cliPropJson` (#2295's `medaka test --json`, slice 4) — both render the
-- same `PropResult` shape for their own independent JSON envelope; neither
-- module imports the other, so not worth a shared module for one 5-line fn.
-- lint-disable-next-line rule-duplicate-body
propJson p = jObject
  [
    ("name", JString (propResultName p)),
    ("status", JString (if propResultPassed p then "pass" else "fail")),
    ("detail", JString (propResultDetail p)),
  ]

allPropsPass : List PropResult -> Bool
allPropsPass [] = True
allPropsPass (p::rest) = propResultPassed p && allPropsPass rest

countPassProps : List PropResult -> Int
countPassProps [] = 0
countPassProps (p::rest) =
  (if propResultPassed p then 1 else 0) + countPassProps rest

countFailProps : List PropResult -> Int
countFailProps [] = 0
countFailProps (p::rest) =
  (if propResultPassed p then 0 else 1) + countFailProps rest

-- The first (today: only) doctest run, keyed off whichever engine actually
-- ran it — `runTestReport` positionally tags each `RunResult` by the `Engine`
-- that produced it, so this never has to assume which one that was.
primaryDoctestRun : List (Engine, RunResult) -> RunResult
primaryDoctestRun [] = RunResult 0 0 0 0 []
primaryDoctestRun ((_, run)::_) = run

-- The run OVERALL passed iff the module type-checked (or was exempted, #1443)
-- AND every engine's doctest run and every property passed.  Drives both the
-- `summary.ok` field and the result's `isError` flag.  A `Some` type error
-- means doctests/props never ran (mirrors `runTestReport`'s gate short-
-- circuit), so it alone forces `False` regardless of `runs`/`props` (both are
-- empty in that case anyway).
testReportOk : Option String -> List (Engine, RunResult) -> List PropResult -> Bool
testReportOk typeError runs props = isNone typeError
  && allDoctestRunsOk runs
  && allPropsPass props

allDoctestRunsOk : List (Engine, RunResult) -> Bool
allDoctestRunsOk [] = True
allDoctestRunsOk ((_, run)::rest) = runFailed run == 0
  && runErrors run == 0
  && allDoctestRunsOk rest

-- The engine name(s) that actually produced `runs` — DERIVED, never a literal
-- "eval": a hardcoded string would silently start lying the day this tool
-- runs more than the interpreter.
doctestRunEngineNames : List (Engine, RunResult) -> List Engine
doctestRunEngineNames [] = []
doctestRunEngineNames ((e, _)::rest) = e :: doctestRunEngineNames rest

-- Today `runs` is always a singleton (`mcpTestEngines == [EngInterp]`), so the
-- top-level "engine" field is that one engine's name — derived from the list
-- that actually ran, never a bare literal.
primaryEngineName : List Engine -> String
primaryEngineName [] = "unknown"
primaryEngineName (e::_) = engineName e

-- #1443: present iff `runTestReport`'s typecheck gate rejected the module —
-- `doctests`/`properties`/`summary` are then the untouched empty defaults
-- (mirrors the CLI's `runTest`, which never reaches `driveAll` on a gate
-- failure either), and `typeError` carries the SAME located error text
-- `medaka test`/`medaka check` would print for this file.
typeErrorField : Option String -> List (String, Json)
typeErrorField None = []
typeErrorField (Some errText) = [("typeError", JString errText)]

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

-- The full structured result body.  `engine`/`note` carry the interpreter
-- caveat INTO the payload (not just the tool description) so a consumer that
-- never read the description is still told what these results cover — and,
-- like the description, both are DERIVED from the engines that actually ran
-- (`doctestRunEngineNames runs`) when the module type-checked, or from the
-- engines that WOULD have run (`mcpTestEngines`) when a type error short-
-- circuited the run before any engine touched it (`runs` is `[]` there, so
-- `doctestRunEngineNames runs` would wrongly read "unknown").
testReportJson : String -> Option String -> List (Engine, RunResult) -> List PropResult -> Bool -> Json
testReportJson path typeError runs props typecheckSkipped =
  let engines = if isNone typeError then
    doctestRunEngineNames runs
  else
    mcpTestEngines
  jObject
    ([
      ("file", JString path),
      ("engine", JString (primaryEngineName engines)),
      ("note", JString (mcpTestCaveat engines)),
    ] ++ typeErrorField typeError ++ typecheckSkippedField typecheckSkipped ++ [
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
            JInt (runFailed (primaryDoctestRun runs) + runErrors (primaryDoctestRun runs) + countFailProps props),
          ),
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
-- `note`, DERIVED from `mcpTestEngines` — see the tool description too.
runTestTool : String -> String -> String -> Json -> <IO> Json
runTestTool runtimeSrc coreSrc stdlibDir args = match fieldStr "file" args
  None => toolArgError "medaka_test: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e => toolArgError (stringConcat ["medaka_test: cannot read file '", path, "': ", e])
    Ok tsrc =>
      -- #2295 (d): `runTestReport` also returns the `test "…"` phase's
      -- structured results (a 4th tuple element, for `medaka test --json`'s
      -- benefit) and (F7) whether the module was typecheck-exempt (a 5th) —
      -- this tool deliberately ignores the former (medaka_test covers
      -- doctests + props only, per #252/#1443) by passing `includeTestDecls =
      -- False`, which (F3) also means the test-decl phase is never EVALUATED
      -- here, not merely unreported — a panicking `test "…"` decl in the
      -- target file can no longer crash the MCP server on this path.
      let (typeError, runs, props, _testResults, typecheckSkipped) = runTestReport mcpTestEngines runtimeSrc coreSrc path tsrc stdlibDir 100 None False
      toolTextResult
        (stringify (testReportJson path typeError runs props typecheckSkipped))
        (not (testReportOk typeError runs props))

-- ── tools/call handler ───────────────────────────────────────────────────────

handleToolsCall : String -> String -> String -> Json -> Json -> (Unit -> <IO> Option String) -> <IO> Unit
handleToolsCall runtimeSrc coreSrc stdlibDir idJson params stalenessCheck = match fieldStr "name" params
  None =>
    writeMessage (errorMsg idJson (0 - 32602) "tools/call: missing 'name'")
  Some name =>
    let args = fieldOr "arguments" params
    let _ = logMcpCall "tools/call" name (stringify args)
    match callTool runtimeSrc coreSrc stdlibDir name args
      None => writeMessage (errorMsg idJson (0 - 32601) (stringConcat ["Unknown tool: ", name]))
      Some result =>
        let augmented = attachStaleness stalenessCheck result
        writeMessage (responseMsg idJson augmented)

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
dispatchMsg : String -> String -> String -> Json -> (Unit -> <IO> Option String) -> String -> <IO> Unit
dispatchMsg runtimeSrc coreSrc stdlibDir msg stalenessCheck serverVersion = match asArray msg
  Some _ => writeMessage
    (errorMsg JNull (0 - 32600) "Invalid Request: batch requests are not supported")
  None => match methodOf msg
    None => logMcp "ignored: message has no string 'method' field"
    Some meth =>
      let params = fieldOr "params" msg
      -- tools/call gets its own richer line (tool name + args) inside
      -- handleToolsCall — don't double-log it here.
      let _ = if meth == "tools/call" then unit else logMcpCall meth "" ""
      if meth == "notifications/initialized" then unit
      else match get "id" msg
        None => unit -- notification: no response for ANY method
        Some idJson =>
          if meth == "initialize" then
            writeMessage (responseMsg idJson (initializeResultFor (negotiateVersion msg) serverVersion))
          else
            if meth == "ping" then writeMessage (responseMsg idJson (jObject []))
            else
              if meth == "shutdown" then writeMessage (responseMsg idJson (jObject []))
              else
                if meth == "tools/list" then writeMessage (responseMsg idJson toolsListResult)
                else
                  if meth == "tools/call" then
                    handleToolsCall runtimeSrc coreSrc stdlibDir idJson params stalenessCheck
                  else writeMessage
                    (errorMsg idJson (0 - 32601) (stringConcat ["Method not found: ", meth]))

-- ── read loop ────────────────────────────────────────────────────────────────

-- Parse and dispatch one input line.  Blank lines and malformed JSON are logged
-- to stderr and skipped, never crashing the stream.
handleLine : String -> String -> String -> String -> (Unit -> <IO> Option String) -> String -> <IO> Unit
handleLine runtimeSrc coreSrc stdlibDir raw stalenessCheck serverVersion =
  let line = stripCR raw
  if line == "" then unit
  else match parse line
    Err e => logMcp (stringConcat ["parse error (skipped): ", e])
    Ok msg => dispatchMsg runtimeSrc coreSrc stdlibDir msg stalenessCheck serverVersion

-- The session loop: one JSON object per line until stdin EOF (clean shutdown).
serveLoop : String -> String -> String -> (Unit -> <IO> Option String) -> String -> <IO> Unit
serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion = match readLineOpt ()
  None => unit
  Some raw =>
    let _ = handleLine runtimeSrc coreSrc stdlibDir raw stalenessCheck serverVersion
    serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion

-- Public entry point for the driver (`runMcpCmd` in medaka_cli.mdk).  The prelude
-- sources + stdlib dir are threaded in so tools can run the compiler pipeline
-- (e.g. medaka_check resolves a `file` target's imports against stdlibDir).
-- `stalenessCheck` is medaka_cli.mdk's `sourceStalenessVerdict`, threaded down
-- as a closure (#846) — see the "staleness signal" section above.
-- `serverVersion` is medaka_cli.mdk's bare `medakaVersion` literal (issue
-- #74 W8), threaded down the same way rather than restating a literal here.
export
runMcpServer : String -> String -> String -> (Unit -> <IO> Option String) -> String -> <IO> Unit
runMcpServer runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion =
  let _ = logMcp "medaka mcp server start"
  serveLoop runtimeSrc coreSrc stdlibDir stalenessCheck serverVersion

unit : Unit
unit = ()
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "Diag" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false) (mem "referencesResult" false) (mem "emptyDocs" false) (mem "docsPut" false) (mem "uriOfPath" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "lintFileDiagTriple" false) (mem "splitLintNames" false) (mem "buildStdlibIndex" false) (mem "StdlibIndex" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestReport" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "Engine" true) (mem "engineName" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EVar "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "logMcpCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "logMcpCall" ((PVar "method") (PVar "name") (PVar "args")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_MCP_LOG"))) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "unit")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "ts") (EApp (EVar "floatToString") (EApp (EVar "wallTimeSec") (ELit LUnit)))) (DoLet false false (PVar "line") (EApp (EVar "stringConcat") (EListLit (EVar "ts") (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "method"))) (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (ELit (LString "\t")) (EVar "args") (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (EVar "unit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "log write failed: ")) (EVar "e")))))))))))
(DTypeSig false "attachStaleness" (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))
(DFunDef false "attachStaleness" ((PVar "stalenessCheck") (PVar "result")) (EMatch (EApp (EVar "stalenessCheck") (ELit LUnit)) (arm (PCon "None") () (EVar "result")) (arm (PCon "Some" (PVar "compilerDir")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "staleBinary"))) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "this server's binary predates the compiler source at ")) (EVar "compilerDir") (ELit (LString " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).")))))) (EVar "result")))))
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
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns the same structured JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. A parse failure returns a distinct `{\"parseError\":true,\"line\",\"col\",\"message\"}` isError, never a silently-empty list."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_references"))) (ELit (LString "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line`/`col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies."))) (EVar "medakaReferencesSchema")) (EVar "runReferencesTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (EVar "mcpTestDescription")) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
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
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr"))))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_check: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (ELit (LString ""))) (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "fieldSymbol" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "fieldSymbol" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "symbol"))) (EVar "args")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "lineTextAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lineTextAt" ((PVar "src") (PVar "line")) (EIf (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EApp (EVar "stringToChars") (EVar "src"))) (EVar "src")) (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lineTextGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "lineTextGo" ((PVar "arr") (PVar "src") (PVar "len") (PVar "i") (PVar "curLine") (PVar "target")) (EIf (EBinOp "==" (EVar "curLine") (EVar "target")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EVar "i"))) (EVar "src"))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EVar "arr")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EVar "target")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EVar "arr")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "target")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lineTextEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineTextEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifiersInLine" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identifiersInLine" ((PVar "text")) (EApp (EApp (EApp (EApp (EVar "identsGo") (EApp (EVar "stringToChars") (EVar "text"))) (EVar "text")) (EApp (EVar "stringLength") (EVar "text"))) (ELit (LInt 0))))
(DTypeSig false "identsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "identsGo" ((PVar "arr") (PVar "text") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identsRunEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "e")) (EVar "text")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "identsGo") (EVar "arr")) (EVar "text")) (EVar "len")) (EVar "e"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "identsGo") (EVar "arr")) (EVar "text")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identsRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identsRunEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EVar "identsRunEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "symbolColsOnLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsOnLine" ((PVar "text") (PVar "symbol")) (EApp (EApp (EVar "symbolColsGo") (EApp (EVar "identifiersInLine") (EVar "text"))) (EVar "symbol")))
(DTypeSig false "symbolColsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsGo" ((PList) PWild) (EListLit))
(DFunDef false "symbolColsGo" ((PCons (PTuple (PVar "name") (PVar "col")) (PVar "rest")) (PVar "symbol")) (EIf (EBinOp "==" (EVar "name") (EVar "symbol")) (EBinOp "::" (EVar "col") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "describeIdentifiers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "describeIdentifiers" ((PList)) (ELit (LString "(none)")))
(DFunDef false "describeIdentifiers" ((PVar "ids")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "identColDesc")) (EVar "ids"))))
(DTypeSig false "identColDesc" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "identColDesc" ((PVar "pair")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "fst") (EVar "pair")) (ELit (LString " (col ")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "pair"))) (ELit (LString ")")))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column (LSP-style). Alternative to 'symbol' — provide exactly one."))))))) (ETuple (ELit (LString "symbol")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'"))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EVar "symbolColsOnLine") (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "' — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText")))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PVar "cols") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtManyCols") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols"))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "typeAtOneCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "typeAtOneCol" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EApp (EVar "typeAtMissNote") (EVar "src")) (EVar "line")) (EVar "col"))) (EVar "False")))))
(DTypeSig false "typeAtMissNote" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "typeAtMissNote" ((PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString " — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))
(DTypeSig false "typeAtManyCols" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Json"))))))))))
(DFunDef false "typeAtManyCols" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EBlock (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "'")) (EVar "symbol") (ELit (LString "' is ambiguous on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " — ")) (EApp (EVar "intToString") (EApp (EVar "length") (EVar "cols"))) (ELit (LString " matches:"))))) (DoLet false false (PVar "bodies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtColLines") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "header") (EVar "bodies")))) (EVar "False")))))
(DTypeSig false "typeAtColLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "typeAtColLines" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_path") (PVar "_src") (PVar "_line") (PList)) (EListLit))
(DFunDef false "typeAtColLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PCons (PVar "col") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": ")) (EVar "ty")))) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": no symbol"))))))) (DoExpr (EBinOp "::" (EVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtColLines") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "rest"))))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "symbolsResult" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "parseError")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "parseErrorLine") (EVar "e")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "parseErrorCol") (EVar "e")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "symbolsResult") (EVar "src")))))))
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
(DTypeSig false "definitionManyCols" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Json")))))))
(DFunDef false "definitionManyCols" ((PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "ambiguous")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "symbol")) (EApp (EVar "JString") (EVar "symbol"))) (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "definitionOneMatch") (EVar "path")) (EVar "src")) (EVar "line"))) (EVar "cols")))))))
(DTypeSig false "definitionOneMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "definitionOneMatch" ((PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EVar "col"))) (ETuple (ELit (LString "result")) (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col")))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'")))))))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EVar "symbolColsOnLine") (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "'")))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PVar "cols") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EVar "definitionManyCols") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols")))) (EVar "False"))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "medakaReferencesSchema" (TyCon "Json"))
(DFunDef false "medakaReferencesSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0)."))))))) (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Include the symbol's own declaration site in the result. Default true.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "referencesParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Json")))))
(DFunDef false "referencesParams" ((PVar "line") (PVar "col") (PVar "includeDecl")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "context")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "JBool") (EVar "includeDecl")))))))))
(DTypeSig false "runReferencesTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runReferencesTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_references: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "includeDecl") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "includeDeclaration"))) (EVar "True")) (EVar "args"))) (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EApp (EApp (EApp (EVar "referencesParams") (EVar "line")) (EVar "col")) (EVar "includeDecl"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EVar "result"))) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "loc") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorLine") (EVar "e"))) (ELit (LString ", col ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorCol") (EVar "e")))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
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
(DTypeSig false "lintPathsToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))
(DFunDef false "lintPathsToDiagTriples" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintPathsToDiagTriples" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "idx") (EVar "buildStdlibIndex")) (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "triples"))) (EApp (EVar "anyTripleHasErr") (EVar "triples"))))))))
(DTypeSig false "mcpTestEngines" (TyApp (TyCon "List") (TyCon "Engine")))
(DFunDef false "mcpTestEngines" () (EListLit (EVar "EngInterp")))
(DTypeSig false "mcpTestEngineHasNative" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "Bool")))
(DFunDef false "mcpTestEngineHasNative" ((PList)) (EVar "False"))
(DFunDef false "mcpTestEngineHasNative" ((PCons (PCon "EngNative") PWild)) (EVar "True"))
(DFunDef false "mcpTestEngineHasNative" ((PCons PWild (PVar "rest"))) (EApp (EVar "mcpTestEngineHasNative") (EVar "rest")))
(DTypeSig false "mcpTestCaveat" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "mcpTestCaveat" ((PVar "engines")) (EIf (EApp (EVar "mcpTestEngineHasNative") (EVar "engines")) (ELit (LString "Results include the NATIVE backend engine (not just the interpreter) — a native-only miscompile is observed here.")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "⚠️ RESULTS ARE UNDER THE INTERPRETER (")) (EApp (EVar "display") (EApp (EVar "engineName") (EVar "EngInterp")))) (ELit (LString "), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mcpTestDescription" (TyCon "String"))
(DFunDef false "mcpTestDescription" () (EBinOp "++" (EBinOp "++" (ELit (LString "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. ")) (EApp (EVar "display") (EApp (EVar "mcpTestCaveat") (EVar "mcpTestEngines")))) (ELit (LString " Bare `test \"…\"` decls are NOT run here."))))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exResultFields" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "exResultFields" ((PCon "Pass")) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "pass"))))))
(DFunDef false "exResultFields" ((PCon "Fail" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "fail")))) (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "exResultFields" ((PCon "Errored" (PVar "msg"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "error")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "msg")))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "primaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "primaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "primaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "testReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))))
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
(DTypeSig false "typeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "typeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "typecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "typecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyCon "Bool") (TyCon "Json")))))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "engines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "doctestRunEngineNames") (EVar "runs")) (EVar "mcpTestEngines"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "primaryEngineName") (EVar "engines")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "mcpTestCaveat") (EVar "engines"))))) (EApp (EVar "typeErrorField") (EVar "typeError"))) (EApp (EVar "typecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "_testResults") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReport") (EVar "mcpTestEngines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EVar "stdlibDir")) (ELit (LInt 100))) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "typecheckSkipped")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params") (PVar "stalenessCheck")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "logMcpCall") (ELit (LString "tools/call"))) (EVar "name")) (EApp (EVar "stringify") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EVar "args")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EBlock (DoLet false false (PVar "augmented") (EApp (EApp (EVar "attachStaleness") (EVar "stalenessCheck")) (EVar "result"))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "augmented"))))))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EVar "unit") (EApp (EApp (EApp (EVar "logMcpCall") (EVar "meth")) (ELit (LString ""))) (ELit (LString ""))))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "get") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))) (EVar "serverVersion")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EVar "stalenessCheck")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg")) (EVar "stalenessCheck")) (EVar "serverVersion"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw")) (EVar "stalenessCheck")) (EVar "serverVersion"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "Diag" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false) (mem "referencesResult" false) (mem "emptyDocs" false) (mem "docsPut" false) (mem "uriOfPath" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "lintFileDiagTriple" false) (mem "splitLintNames" false) (mem "buildStdlibIndex" false) (mem "StdlibIndex" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestReport" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "Engine" true) (mem "engineName" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EDictApp "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "logMcpCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "logMcpCall" ((PVar "method") (PVar "name") (PVar "args")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_MCP_LOG"))) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "unit")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "ts") (EApp (EVar "floatToString") (EApp (EVar "wallTimeSec") (ELit LUnit)))) (DoLet false false (PVar "line") (EApp (EVar "stringConcat") (EListLit (EVar "ts") (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "method"))) (ELit (LString "\t")) (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (ELit (LString "\t")) (EVar "args") (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (EVar "unit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "log write failed: ")) (EVar "e")))))))))))
(DTypeSig false "attachStaleness" (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))
(DFunDef false "attachStaleness" ((PVar "stalenessCheck") (PVar "result")) (EMatch (EApp (EVar "stalenessCheck") (ELit LUnit)) (arm (PCon "None") () (EVar "result")) (arm (PCon "Some" (PVar "compilerDir")) () (EApp (EApp (EApp (EVar "jsonObjectAppend") (ELit (LString "staleBinary"))) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "this server's binary predates the compiler source at ")) (EVar "compilerDir") (ELit (LString " — results may reflect the OLD compiler. Rebuild with 'make medaka' and reconnect (/mcp).")))))) (EVar "result")))))
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
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "FIRST CHOICE over shelling out to `medaka check` for any type-check/diagnostic query: returns the same structured JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available) — act on it directly instead of parsing CLI text. Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "FIRST CHOICE for \"what type is this\" instead of re-deriving it by hand — infer the type/scheme at a position (stateless hover). Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting); returns `<name> : <type>`. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "FIRST CHOICE for a file's outline instead of grepping for `data`/`impl`/`fn` headers — lists top-level declarations with source ranges. Give `file`; parse-only, so it works even on a file with type errors. One entry per multi-clause function, not one-per-clause. A parse failure returns a distinct `{\"parseError\":true,\"line\",\"col\",\"message\"}` isError, never a silently-empty list."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "FIRST CHOICE for \"where is X defined\" WITHIN THIS FILE instead of grepping — go-to-definition. Give `file` plus `line` and either `col` (0-based, LSP-style) or `symbol` (a name to locate on that line — no column counting). INTRA-FILE ONLY: a name defined elsewhere returns empty — reach for `medaka_references` on a cross-file lookup instead. A miss names the identifiers actually on that line instead of a bare empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_references"))) (ELit (LString "FIRST CHOICE for \"find every use of X\" instead of grep — resolves by BINDER IDENTITY, not spelling, so it is correct under shadowing, import aliasing, and same-name-in-different-modules, where grep is not. Give `file` plus 0-based `line`/`col`; optional `includeDeclaration` (default true). Project-wide, read-only; never descends into stdlib bodies."))) (EVar "medakaReferencesSchema")) (EVar "runReferencesTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "FIRST CHOICE for formatting Medaka source instead of shelling out to `medaka fmt`. Provide exactly one of `file` or `source`. NEVER writes to disk — apply the returned text yourself. Pass `check: true` for a clean/dirty verdict only (no full text)."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "FIRST CHOICE for style-linting Medaka source instead of shelling out to `medaka lint`. Give `paths` (array of file paths); narrow with comma-separated `deny`/`only`/`disable`. Report-only (no autofix) — same diagnostic schema as `medaka_check`."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (EVar "mcpTestDescription")) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
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
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr"))))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_check: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (ELit (LString ""))) (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "fieldSymbol" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "fieldSymbol" ((PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "symbol"))) (EVar "args")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "lineTextAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lineTextAt" ((PVar "src") (PVar "line")) (EIf (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EApp (EVar "stringToChars") (EVar "src"))) (EVar "src")) (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lineTextGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "lineTextGo" ((PVar "arr") (PVar "src") (PVar "len") (PVar "i") (PVar "curLine") (PVar "target")) (EIf (EBinOp "==" (EVar "curLine") (EVar "target")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EVar "i"))) (EVar "src"))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EVar "arr")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EVar "target")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineTextGo") (EVar "arr")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "target")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lineTextEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineTextEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineTextEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifiersInLine" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "identifiersInLine" ((PVar "text")) (EApp (EApp (EApp (EApp (EVar "identsGo") (EApp (EVar "stringToChars") (EVar "text"))) (EVar "text")) (EApp (EVar "stringLength") (EVar "text"))) (ELit (LInt 0))))
(DTypeSig false "identsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "identsGo" ((PVar "arr") (PVar "text") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identsRunEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "e")) (EVar "text")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "identsGo") (EVar "arr")) (EVar "text")) (EVar "len")) (EVar "e"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "identsGo") (EVar "arr")) (EVar "text")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identsRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identsRunEnd" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EVar "identsRunEnd") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "symbolColsOnLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsOnLine" ((PVar "text") (PVar "symbol")) (EApp (EApp (EVar "symbolColsGo") (EApp (EVar "identifiersInLine") (EVar "text"))) (EVar "symbol")))
(DTypeSig false "symbolColsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "symbolColsGo" ((PList) PWild) (EListLit))
(DFunDef false "symbolColsGo" ((PCons (PTuple (PVar "name") (PVar "col")) (PVar "rest")) (PVar "symbol")) (EIf (EBinOp "==" (EVar "name") (EVar "symbol")) (EBinOp "::" (EVar "col") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "symbolColsGo") (EVar "rest")) (EVar "symbol")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "describeIdentifiers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "describeIdentifiers" ((PList)) (ELit (LString "(none)")))
(DFunDef false "describeIdentifiers" ((PVar "ids")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "identColDesc")) (EVar "ids"))))
(DTypeSig false "identColDesc" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "identColDesc" ((PVar "pair")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "fst") (EVar "pair")) (ELit (LString " (col ")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "pair"))) (ELit (LString ")")))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column (LSP-style). Alternative to 'symbol' — provide exactly one."))))))) (ETuple (ELit (LString "symbol")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Name to locate on 'line' instead of counting columns — resolved server-side against the line's own text. Alternative to 'col' — provide exactly one.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'"))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EVar "symbolColsOnLine") (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "' — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText")))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtOneCol") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col"))) (arm (PVar "cols") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtManyCols") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols"))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "typeAtOneCol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "typeAtOneCol" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EApp (EVar "typeAtMissNote") (EVar "src")) (EVar "line")) (EVar "col"))) (EVar "False")))))
(DTypeSig false "typeAtMissNote" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "typeAtMissNote" ((PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col"))))) (arm (PCon "Some" (PVar "lineText")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "no symbol at line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString " — identifiers on this line: ")) (EApp (EVar "describeIdentifiers") (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))
(DTypeSig false "typeAtManyCols" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Json"))))))))))
(DFunDef false "typeAtManyCols" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EBlock (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "'")) (EVar "symbol") (ELit (LString "' is ambiguous on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " — ")) (EApp (EVar "intToString") (EApp (EMethodRef "length") (EVar "cols"))) (ELit (LString " matches:"))))) (DoLet false false (PVar "bodies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtColLines") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "cols"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "header") (EVar "bodies")))) (EVar "False")))))
(DTypeSig false "typeAtColLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "typeAtColLines" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_path") (PVar "_src") (PVar "_line") (PList)) (EListLit))
(DFunDef false "typeAtColLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "path") (PVar "src") (PVar "line") (PCons (PVar "col") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": ")) (EVar "ty")))) (arm (PCon "None") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "  col ")) (EApp (EVar "intToString") (EVar "col")) (ELit (LString ": no symbol"))))))) (DoExpr (EBinOp "::" (EVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtColLines") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "rest"))))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "symbolsResult" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "parseError")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "parseErrorLine") (EVar "e")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "parseErrorCol") (EVar "e")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "symbolsResult") (EVar "src")))))))
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
(DTypeSig false "definitionManyCols" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Json")))))))
(DFunDef false "definitionManyCols" ((PVar "path") (PVar "src") (PVar "line") (PVar "symbol") (PVar "cols")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "ambiguous")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "symbol")) (EApp (EVar "JString") (EVar "symbol"))) (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "definitionOneMatch") (EVar "path")) (EVar "src")) (EVar "line"))) (EVar "cols")))))))
(DTypeSig false "definitionOneMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "definitionOneMatch" ((PVar "path") (PVar "src") (PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EVar "col"))) (ETuple (ELit (LString "result")) (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col")))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (ETuple (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args")) (EApp (EVar "fieldSymbol") (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: provide exactly one of 'col' (integer) or 'symbol' (string), not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing argument — provide 'col' (integer) or 'symbol' (string)")))) (arm (PTuple (PCon "Some" (PVar "col")) (PCon "None")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "symbol"))) () (EMatch (EApp (EApp (EVar "lineTextAt") (EVar "src")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " does not exist in '")) (EVar "path") (ELit (LString "'")))))))))) (EVar "False"))) (arm (PCon "Some" (PVar "lineText")) () (EMatch (EApp (EApp (EVar "symbolColsOnLine") (EVar "lineText")) (EVar "symbol")) (arm (PList) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "matches")) (EApp (EVar "jArray") (EListLit))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "stringConcat") (EListLit (ELit (LString "no identifier named '")) (EVar "symbol") (ELit (LString "' on line ")) (EApp (EVar "intToString") (EVar "line")) (ELit (LString " of '")) (EVar "path") (ELit (LString "'")))))) (ETuple (ELit (LString "identifiersOnLine")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "identPairJson")) (EApp (EVar "identifiersInLine") (EVar "lineText"))))))))) (EVar "False"))) (arm (PList (PVar "col")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EVar "definitionAtCol") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")))) (EVar "False"))) (arm (PVar "cols") () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EVar "definitionManyCols") (EVar "path")) (EVar "src")) (EVar "line")) (EVar "symbol")) (EVar "cols")))) (EVar "False"))))))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and one of 'col' (integer) or 'symbol' (string)"))))))
(DTypeSig false "medakaReferencesSchema" (TyCon "Json"))
(DFunDef false "medakaReferencesSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0)."))))))) (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Include the symbol's own declaration site in the result. Default true.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "referencesParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Json")))))
(DFunDef false "referencesParams" ((PVar "line") (PVar "col") (PVar "includeDecl")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))) (ETuple (ELit (LString "context")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "includeDeclaration")) (EApp (EVar "JBool") (EVar "includeDecl")))))))))
(DTypeSig false "runReferencesTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runReferencesTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_references: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "includeDecl") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "includeDeclaration"))) (EVar "True")) (EVar "args"))) (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EApp (EApp (EApp (EVar "referencesParams") (EVar "line")) (EVar "col")) (EVar "includeDecl"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EVar "result"))) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_references: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "loc") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorLine") (EVar "e"))) (ELit (LString ", col ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorCol") (EVar "e")))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
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
(DTypeSig false "lintPathsToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))
(DFunDef false "lintPathsToDiagTriples" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintPathsToDiagTriples" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "idx") (EVar "buildStdlibIndex")) (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "triples"))) (EApp (EVar "anyTripleHasErr") (EVar "triples"))))))))
(DTypeSig false "mcpTestEngines" (TyApp (TyCon "List") (TyCon "Engine")))
(DFunDef false "mcpTestEngines" () (EListLit (EVar "EngInterp")))
(DTypeSig false "mcpTestEngineHasNative" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "Bool")))
(DFunDef false "mcpTestEngineHasNative" ((PList)) (EVar "False"))
(DFunDef false "mcpTestEngineHasNative" ((PCons (PCon "EngNative") PWild)) (EVar "True"))
(DFunDef false "mcpTestEngineHasNative" ((PCons PWild (PVar "rest"))) (EApp (EVar "mcpTestEngineHasNative") (EVar "rest")))
(DTypeSig false "mcpTestCaveat" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "mcpTestCaveat" ((PVar "engines")) (EIf (EApp (EVar "mcpTestEngineHasNative") (EVar "engines")) (ELit (LString "Results include the NATIVE backend engine (not just the interpreter) — a native-only miscompile is observed here.")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "⚠️ RESULTS ARE UNDER THE INTERPRETER (")) (EApp (EMethodRef "display") (EApp (EVar "engineName") (EVar "EngInterp")))) (ELit (LString "), NOT the native backend — report as \"passes under eval\", never unqualified (#81)."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mcpTestDescription" (TyCon "String"))
(DFunDef false "mcpTestDescription" () (EBinOp "++" (EBinOp "++" (ELit (LString "FIRST CHOICE for running a file's doctests/property tests instead of `medaka test` via Bash. Give `file`. ")) (EApp (EMethodRef "display") (EApp (EVar "mcpTestCaveat") (EVar "mcpTestEngines")))) (ELit (LString " Bare `test \"…\"` decls are NOT run here."))))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exResultFields" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "exResultFields" ((PCon "Pass")) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "pass"))))))
(DFunDef false "exResultFields" ((PCon "Fail" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "fail")))) (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "exResultFields" ((PCon "Errored" (PVar "msg"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "error")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "msg")))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "primaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "primaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "primaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "testReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))))
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
(DTypeSig false "typeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "typeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "typecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "typecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "typecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyCon "Bool") (TyCon "Json")))))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "engines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "doctestRunEngineNames") (EVar "runs")) (EVar "mcpTestEngines"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "primaryEngineName") (EVar "engines")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (EApp (EVar "mcpTestCaveat") (EVar "engines"))))) (EApp (EVar "typeErrorField") (EVar "typeError"))) (EApp (EVar "typecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "primaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "primaryDoctestRun") (EVar "runs")))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "_testResults") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReport") (EVar "mcpTestEngines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EVar "stdlibDir")) (ELit (LInt 100))) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "typecheckSkipped")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params") (PVar "stalenessCheck")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "logMcpCall") (ELit (LString "tools/call"))) (EVar "name")) (EApp (EVar "stringify") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EVar "args")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EBlock (DoLet false false (PVar "augmented") (EApp (EApp (EVar "attachStaleness") (EVar "stalenessCheck")) (EVar "result"))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "augmented"))))))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EVar "unit") (EApp (EApp (EApp (EVar "logMcpCall") (EVar "meth")) (ELit (LString ""))) (ELit (LString ""))))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "get") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))) (EVar "serverVersion")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EVar "stalenessCheck")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg")) (EVar "stalenessCheck")) (EVar "serverVersion"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw")) (EVar "stalenessCheck")) (EVar "serverVersion"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "stalenessCheck") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "stalenessCheck")) (EVar "serverVersion")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
