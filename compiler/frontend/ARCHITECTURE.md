# frontend/ — source text to resolved, marked AST

**Status:** CURRENT — re-derived from source at f804ff533441d3691c10e8dcee311e78e02ddaec on 2026-10-27. The planned lexer boundary below is a design, not a description of the current implementation.

## What this directory is
The first four stages of the pipeline (`ARCHITECTURE.md` section 1): lexer, parser, desugar,
resolve, plus the marker and the pre-desugar guard-exhaustiveness check. It sits just above
`support/` in the layering (A1). It consumes source text and produces the surface AST, then the
desugared and resolved AST that `types/` infers over. Syntactic only: no type information.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `ast.mdk` | The surface (pre-desugar) AST nodes the parser builds; post-parse-only nodes are omitted by design | `Lit`, `Expr`, `Decl`, `Pat` |
| `ast_codec.mdk` | The compact s-expression codec for elaborated declarations and evidence rows: an `SExp` writer and a cursor reader that fails closed; imports `ast` and `support/` only | `declsSExp`, `readDecls`, `decodeDecls`, `evEntriesSExp`, `decodeEvEntries` |
| `parse_diagnostic.mdk` | Structured parse problems, locations, edits and rendering | `ParseDiagnostic`, `ParseDiagnosticKind`, `locateParseProblem`, `renderParseDiagnostic` |
| `lex_token.mdk` | Token and raw-token types, token descriptions, predicates and EOF-clamped token access | `Token`, `RawTok`, `describeToken`, `peekTok` |
| `parse_locate.mdk` | Token offsets and typed diagnostic locations; imports only `lex_token`, `parse_diagnostic` and `support/source_index` | `locateOffset`, `locateTokenDiagnostic` |
| `parse_hints.mdk` | Syntax-only removed-form and contextual recognition, using a lazy invocation-scoped source index | `prescanDiagnostic`, token-shape helpers |
| `lexer.mdk` | Tokenizer plus the INDENT/DEDENT/NEWLINE layout pass | `tokenize`, `tokenizeWithOffsetPairs` |
| `parse_positions.mdk` | Derives immutable declaration positions from tokens and spans | `Positions`, `DeclPos`, `positionsFromSpans` |
| `parse_engine.mdk` | Parse contexts, combinators, rollback and cue recording | `Parser`, `ParseContext`, `runPWith`, `mark`, `rewind` |
| `parse_result.mdk` | Immutable parsed declarations, positions, metadata and parse errors | `ParsedSource`, `ParseMetadata`, `ParseError`, `parsedDecls` |
| `parser.mdk` | Grammar over parse-engine contexts and tokens; stratified operator ladder | `parse`, `parseLocated`, `parseResult`, `parseSource` |
| `desugar.mdk` | Lowers sugar (guards, sections, interpolation, comprehensions, do, `?`, deriving) to the core AST; runs after parse, before resolve; owns the shared `mapExpr`/`mapDecl` traversal | `desugar` |
| `resolve.mdk` | Name environment and scope checks: unbound names, duplicates, privacy; single-file and multi-module paths | `resolveProgram`, `resolveModulesToLines` |
| `visibility.mdk` | A module's export surface, built from its declarations and the surfaces of the modules it re-exports; imports no resolver state | `ModuleExports`, `buildExportsWith`, `coreExports` |
| `marker.mdk` | Rewrites interface-method and constrained-function occurrences to marked nodes; not on `check`/`run`/`build` (typecheck marks per binding group) | `markWithPrelude` |
| `exhaust.mdk` | Guard-fall-through check on the raw pre-desugar AST via the pattern-matrix `useful` recursion; match exhaustiveness is in `types/` | `checkGuardExhaustiveness` |

Match-arm commitment belongs to the parser. Optional continuation advice belongs
to `parse_hints`: `matchContinuationHint` receives tokens, offset pairs, line
starts and the match and arm token positions, and returns a diagnostic kind.
It recognizes only balanced parenthesized arrow islands with a supported header
anchor and an immediately following plausible arm. Shared pattern/expression
forms and uncertain shapes suppress advice. An invocation-owned tab flag suppresses
advice when source contains a tab; a root `->` before a following arm also
suppresses it. The flag retains neither source nor provider. Each attempt visits at most 4096
tokens and bounds delimiter depth; it retains no parse context or source index.
The advice is conditional and cannot decide acceptance.
| `parse_cache.mdk` | Source-keyed memo of the implicit prelude parse | `parsePrelude` |
| `desugar_cache.mdk` | Source-keyed memo of the desugared prelude, a sibling tier above `parse_cache`, bounded at four entries. An entry is either a tree minted under a fresh generation, or a pending decoder for the text's shipped tree (`registerPreludeDecls`) that runs on the text's first demand and falls back to parse and desugar when it yields nothing. `preludeGeneration` returns the generation pair of the two prelude texts, the key the prelude caches are keyed by | `desugaredPrelude`, `desugaredPreludeKey`, `preludeGeneration`, `registerPreludeDecls` |

## Planned lexer boundary

The current lexer owns scanning, literals and layout. The adopted extraction keeps
`lexer` as the public facade and moves those decision bodies into three planned
frontend modules. Their dependency graph is acyclic: lexer calls lex_scan and
lex_layout; lex_scan calls lex_literal; both lex_literal and lex_layout use
lex_token, which depends on parse_diagnostic and ast. The owners may use
support char, util and stage_count and selected stdlib functions; they must not
import parser, driver, tools, types, IR or backend. The facade alone retains its
existing source-index position adapters. SourceIndex holds coordinates, not source
text: scanning takes a String or Array Char, never constructs or forces an index,
and diagnostic/recovery callers retain their lazy index provider.

- **lex_literal** owns plain and triple literal segments, character and escape
  decoding, range copying and triple dedent. Its planned public data are
  LiteralFlavor (PlainLiteral, TripleLiteral), LiteralPart (InitialLiteral,
  ContinuedLiteral), LexError (diagnostic kind and start/end offsets),
  LiteralCursor (position, opening quote, flavor, part, leading raw LF and
  inside-hole flag), LiteralStop (LiteralClose or LiteralHole), and LiteralRead
  (decoded segment, next offset, stop and leading raw LF). Its functions are
  `readLiteral : Array Char -> LiteralCursor -> Result LexError LiteralRead`,
  `readCharacter : Array Char -> Int -> Result LexError (String, Int)`,
  `copyCharRange : Array Char -> Int -> Int -> String`,
  `dedentSegments : List String -> List String`, and
  `dedentTripleInterp : List RawTok -> List RawTok`. Segment builders batch
  owned fragments and join once; they do not append per character or retain the source.
- **lex_scan** owns raw scanning, numbers, identifiers, operators, comments and
  newlines. Its planned exports are `scanRaw : String -> List RawTok`,
  `scanRawChars : Array Char -> List RawTok`, and
  `scanRawUndedentedChars : Array Char -> List RawTok`; the last serves comment
  collection without dedent or layout. There is no separate recovering scanner.
  A finite CodeFrame or HoleFrame (literal flavor, opener offset and positive
  brace depth) replaces signed-depth flavor encoding. An inner plain or triple
  string is read synchronously in a hole; an actual nested interpolation opener
  is a terminal local error at its two-character span. Sequential outer holes
  remain supported. Triple interpolation opener metadata survives dedent.
- **lex_layout** owns extern-clause breaks, layout and the final filter. Its
  planned exports are `applyLayoutTokens : List RawTok -> List Token`,
  `applyLayoutStarts : List RawTok -> List (Token, Int)`, and
  `applyLayoutRanges : List RawTok -> List (Token, Int, Int)`. One private
  engine emits only the requested projection, without allocating unused
  coordinates. It preserves existing synthetic offsets and layout decisions.

The facade retains these current public functions:

```text
tokenize : String -> List Token
tokenizeWithLines : String -> (List Token, List Int)
tokenizeWithOffsets : String -> (List Token, List Int)
tokenizeWithOffsetPairs : String -> (List Token, List (Int, Int))
collectComments : String -> List Comment
commentLine : Comment -> Int
commentCol : Comment -> Int
commentText : Comment -> String
offsetToLineCol : String -> Int -> (Int, Int)
isThenTok : Token -> Bool
isElseTok : Token -> Bool
```

It also retains Comment, Token and BracketFrame re-exports, token renderers,
lineStartsOf and offsetToLineColFast. BracketFrame moves to layout; isThenTok and isElseTok move
to lex_token and are re-exported by the facade. First move literal and scanner
bodies together, including the shared range copier and triple dedent, without
live twins. Then move the range layout family and extern breaks, parameterize
its projections and delete the old layout and filter twins. The facade keeps
only delegation and comment/position adapters. Existing consumers need no API
rewrite. These planned modules and the dedicated nested-interpolation
diagnostic are not yet implemented.

The prototype's matched batches measured complete ordinary-source tokenization
at 1.191x, 1.094x and 1.216x baseline: the accepted tradeoff permits up to
1.35x time and 1.05x allocation for matched batches while removing literal
quadratics. Allocation doubling is bounded at 2.30 and output-only retained
heap at 1.10x baseline plus 64 KiB. Coordinates remain decoded-character offsets;
UTF-16 projection stays with SourceIndex.

## Laws that bind it
- **A1** — frontend imports only `support/` (and stdlib); it must not know Core IR, LLVM or any CLI verb.
- **A2** — `ast.mdk` carries no mutable field in the destination; today the typechecker writes dispatch routes into `Ref` cells that `ast.mdk` declares, which Phase 1 of the playbook removes.
- **A9** — the import closure of `frontend/ast.mdk` is a committed golden; adding an import to it fails the check.
- **A8** — a new frontend subsystem is a new module, as `parse_cache` and `desugar_cache` were.

## Boundaries and checks
- `parse_locate` is the single owner of token offset and EOF location rules. The
  parser and syntax hints both call it; parser adapters wrap typed diagnostics as
  `ParseError`. `parse_hints` depends only on token, diagnostic, location and
  support modules, never grammar or tools. Its index provider is invocation-owned
  and does not escape. Prescan bodies migrate out of `parser`; existing parser
  prescan APIs remain compatibility adapters.
- Planned recovery owns current-source partial syntax in `parse_recovery` and
  immutable `recovery_result` values. It drives the strict declaration grammar
  at trustworthy root fences, stops at ambiguous delimiters or terminal lexical
  errors, and never sends partial results to semantic or execution pipelines.
  Snapshot identity and UTF-16 projection remain tool responsibilities.
- `test/arch_boundaries_test.mdk` pins layering edges, module-level cells, the hooks record and the leaf-module import closures.
- `test/arch_goldens/closure.frontend.ast.golden` is the closure of `ast.mdk`; `layering.golden` and `cells.golden` are the repo-wide counts.
- `test/arch_ratchet.sh` fails a rise in any pinned number unless a commit trailer names it.
- `test/stage_counts_test.mdk` pins per-stage work counts (`test/arch_goldens/stage_counts.golden`).
- Lexer, parser and desugar outputs are pinned by the snapshot corpus (`[T-SNAPSHOT-SELF]`).

## Where the design lives
- `ARCHITECTURE.md` and `ARCHITECTURE-PLAYBOOK.md` for the laws and the plan (`A2` is playbook Phase 1).
- `docs/spec/SYNTAX.md` and `docs/spec/LAYOUT-SEMANTICS.md` for syntax and layout ground truth.
- `ERROR-QUALITY.md` and `DIAGNOSTIC-CODES-DESIGN.md` for diagnostics wording and codes.

## Traps
- `[P-DESUGAR-FIRST]` — desugar runs before resolve and typecheck; sugar-shape checks must run on the raw AST.
- `[P-NO-MARK-PASS]` — `markWithPrelude` is not on a production verb.
- `[T-LAYOUT-SPEC]` — a token stream the parser cannot consume is a parser bug.
- `[T-GLOBAL-TABLE]` — a new AST constructor means auditing every `_ =>` arm.
- `[DG-REMOVED]` — removed syntax is a hard parse error, not a warning.
