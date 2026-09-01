# playground/NOTES.md — the docs render machine

Landed by **S-render-machine** (sprint `guide-on-the-site`, #2386). This file is the
handoff contract for the slices that build on top of it.

## The pieces

| File | What it is |
|---|---|
| `build_marked.sh` | ONE-TIME vendoring of `marked` 18.0.11 → `vendor/marked/marked.js`. Needs network. Re-run only to bump the version. |
| `vendor/marked/marked.js` | The committed 43 KB single-ESM bundle. **Do not edit by hand.** |
| `render_docs.mjs` | The renderer. Doc-set-agnostic: `--src <dir> --out <dir>`. |
| `build_guide.sh` | Convention entry point: `docs/guide` → `playground/site-guide/`. |
| `guide_render_test.mjs` | Standalone assertion gate over the rendered output. |

Everything except `build_marked.sh` runs offline: `bash playground/build_guide.sh`
needs only `node` and the committed bundle.

## Output shape S-2 depends on

Every fenced code block renders as:

```html
<div class="codeblock kind-medaka"
     data-lang="medaka"
     data-fence="medaka"
     data-source="…the exact fence body, HTML-escaped…">
  <pre><code class="language-medaka">…the same text, escaped…</code></pre>
</div>
```

- `data-lang` — the **normalized** fence label: the token before any `:` or
  whitespace, so `medaka-nocheck: stdlib declarations…` normalizes to
  `medaka-nocheck`.
- `data-fence` — the **raw** info string, prose and all (empty for an unlabelled
  fence or a 4-space-indented block).
- `data-source` — the fence body verbatim, HTML-escaped. This is the recovery
  channel: an "open in playground" pass reads it off the `<div>` and never
  re-parses the Markdown.
- `kind-*` classes: `kind-medaka` (`medaka`, `medaka-project`, `medaka-nocheck`),
  `kind-output` (`medaka-expect`), `kind-toml`, `kind-plain`.

Fence labels are a **closed set** (`KNOWN_FENCES` in `render_docs.mjs`). An unknown
label is a hard error, never a silent fall-through to unhighlighted prose — a doc
that grows a new fence kind must teach the renderer about it.

Headings carry `id="<slug-of-text>"`, collision-safe with a `-1`, `-2` … suffix in
document order, plus a `<a class="anchor">` permalink. Each page has a
`<nav class="toc">` over its `##`/`###` headings, and a `<nav class="chapters">`
sidebar over the whole doc set.

## Link rewriting

The source `.md` files are **never edited** (`make docs-links` gates those). The
rewrite is entirely in the rendered output:

- an in-set bare sibling `foo.md[#frag]` → `foo.html[#frag]` — the 44 cross-chapter
  links;
- a bare sibling `.md` that is **not** in the rendered set → **hard error** (a
  broken cross-chapter link, not an out-of-set one);
- any other repo-relative path (`../spec/SYNTAX.md#…`, `../../stdlib/core.mdk` — 21
  of them) → the GitHub blob URL under `--repo-url`
  (default `https://github.com/MedakaLang/medaka/blob/main`). Pass `--repo-url ''`
  to leave those alone. **This is a default, not a ruling** — if the site later
  renders `docs/spec/`, point the renderer at that doc set instead.
- absolute URLs and bare `#anchors` are untouched.

## For S-site-wiring (S-3)

- Staging dir is `playground/site-guide/` (gitignored, like `playground/site/`). It
  contains one `.html` per chapter plus a generated `guide.css`.
- `build_site.sh` was deliberately **not** touched, per this slice's packet.
- `build_marked.sh` and `build_guide.sh` are already registered in
  `test/CI-COVERAGE-TOOLS.txt`. Without those entries `_gate_candidates()` in
  `test/preflight.sh` would treat them as gates and **execute** them — for
  `build_marked.sh` that means a live `npm install`.
- ⚠️ `guide_render_test.mjs` is a `.mjs`, so it is invisible to
  `test/diff_compiler_ci_shard_coverage.sh` (which enumerates `*.sh`) and **runs in
  no CI job today** — same as the five pre-existing `playground/*_test.mjs` files,
  none of which any gate or workflow invokes. Wiring it up is S-3's call; if you
  wrap it in a `.sh`, that wrapper needs a `test/gates.toml` row and the
  `[W-SHARD-DERIVED]` cost-baseline dance.

## OUTLINE.md

`docs/guide/OUTLINE.md` is the guide's planning document (chapter plan, word
budgets), not a chapter. `build_guide.sh` passes `--exclude OUTLINE.md`, so it is
**not published**. Nothing in the guide links to it, so nothing breaks.
