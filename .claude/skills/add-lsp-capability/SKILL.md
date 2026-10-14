---
name: add-lsp-capability
description: Add or extend an LSP feature in compiler/tools/lsp.mdk (hover, completion, code actions, references, rename, …).
---

# Add an LSP capability

All LSP work lives in `compiler/tools/lsp.mdk` (stdio JSON-RPC). Existing
handlers cover diagnostics, formatting, document symbols, hover, definition,
highlight, completion, and inlay hints — use the nearest one as a template.

When examples involve **Medaka** code, use `x y => body`, never curried form.

## Wiring (three places)

All three are in `compiler/tools/lsp.mdk`. Line numbers are as of 2026-10-13 —
grep the name, not the number.

1. **Advertise the capability** — `initializeResultFor` (`:1597`). It is a plain
   top-level **function** of the server version, not a record type:
   `initializeResultFor : String -> Json` (the argument is `serverVersion`,
   threaded from the driver), built with `jObject`. Its `"capabilities"` object
   (`:1600`) already lists `textDocumentSync`, `documentFormattingProvider`,
   `documentSymbolProvider`, `definitionProvider`, `documentHighlightProvider`,
   `referencesProvider`, `hoverProvider`, `completionProvider`, `inlayHintProvider`,
   `semanticTokensProvider`. Add your provider field there so clients know the
   feature exists.
2. **Implement the handler** — add a `handle<Feature>` function next to the
   existing ones. Real templates: `handleHover` (`:993`), `handleCompletion`
   (`:1119`), `handleInlayHint` (`:1231`) — all with the shape
   `String -> String -> Json -> Json -> Docs -> <IO> Unit`
   (`runtimeSrc`, `coreSrc`, the request id, the params `Json`, and the open-document
   table). They write the response themselves rather than returning a value.
3. **Dispatch** — `dispatch` (`:2047`),
   `dispatch : String -> String -> String -> Json -> Docs -> <IO> Step` (the third
   argument is `serverVersion`). It matches on `methodOf msg` (`:2040`) — add an
   arm for your request's method string and call your handler.

## Implementing `rename` (or extending `references`)

`textDocument/references` is already wired (`handleReferences`, `:1873`; dispatch arm
`:2076`; advertised as `referencesProvider`) on this substrate. `rename` is not wired
yet, and the same substrate is the evident foundation for it.

The substrate is `compiler/tools/refindex.mdk` (driven standalone by
`compiler/entries/refindex_main.mdk`). It builds a whole-project binder-keyed def/use
index, shadow-aware and alias/re-export-collapsing. Read its header before building
`rename`.

## Get analysis results

- Open documents live in the `Docs` table (`data Docs`, `:95`), threaded through
  every handler as the `docs` parameter; read/write with `docsGet` (`:209`) /
  `docsPut` (`:105`). Resolve by URI.
- Run the compiler front end through the **loader** (multi-file aware) the same
  way the existing handlers do — reuse the shared analysis helper rather than
  re-invoking stages directly.
- **Resilience:** mid-edit buffers often don't parse. The server keeps a
  session-lived last-good-source cache — **`projectCache : Ref (List (String,
  String))`** (`:1645`), a module-level `Ref` mapping file path → last source that
  parsed, **not** a table type. Features degrade gracefully instead of going blank
  on a transient parse error; fall back to last-good like neighboring handlers do.

## Verify

`main` is PROTECTED — branch, then land via PR. Before committing:

```sh
medaka fmt --write compiler/tools/lsp.mdk   # the pre-commit hook REJECTS unformatted .mdk
medaka lint compiler/tools/lsp.mdk          # the hook is a MAX RATCHET: any new finding fails
make preflight
```

Then:

```sh
./medaka gate run diff_compiler_lsp
```

One gate now holds every LSP request set as rows of a table
(`test/diff_compiler_lsp_test.mdk`); add yours there rather than beside it.

New LSP output almost always **moves an LSP golden**. Re-mint it by NAME
(`sh test/lsp_bless.sh b4_inlay.ndjson`) and stage it in the **same commit**, or
`main` goes red. Read the diff first: six of the ten goldens are dumps of the
server under test, so a capture is not evidence that the new answer is right.

For an end-to-end stdio check, use `test/lsp_harness_test.mdk`. The harness drives
the **compiled** `medaka lsp` binary over JSON-RPC — run `make medaka` first.
If your feature depends on new language syntax, see the `add-language-feature`
skill first.
