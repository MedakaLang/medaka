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

## Does the guide's promise hold? (S-prove-the-promise, S-4)

Every ▶ Open in Playground button is a promise: *click this and it runs*. Nothing
checked it, so `playground/guide_wasm_differential.mjs` does. It compiles each
runnable example with `playground/dist/playground.wasm` — the same WasmGC
compiler blob the page loads — through `playground/compile.mjs`, the same seam
`compiler-worker.js` imports, over the same `dist/*.mdk` module set `main.js`
fetches; assembles the WAT and runs it under Node ≥24; and diffs stdout, stderr
AND exit code against `medaka build`'s native binary.

```sh
bash playground/build_site.sh                     # needs site/guide + dist/
node playground/guide_wasm_differential.mjs       # add --list, --only <id>, --json <path>
```

**Result at the time of writing: 56 matched / 3 wasm divergence / 6 rule gap, of
65.** Of the 56, all 55 that carry a `medaka-expect` fence print exactly what the
guide says they print.

The three **wasm divergences** are compiler bugs, not guide bugs — each works
natively and fails only on the browser's path. Minimal repros are in the
S-prove-the-promise sprint report; none is fixed here.

The six **rule gaps** are a different animal: on those, native and browser AGREE
that the program cannot run, so the runnable partition should never have offered
a ▶ button. `classifyRunnable` in `render_docs.mjs` asks two questions — is the
fence label exactly `medaka`, and does the source call a stubbed capability — and
it needs two more:

1. **does the block define a top-level `main`?** Five blocks do not
   (`02-expressions#7/#8/#14`, `04-data-modeling#1`, `09-modules-and-projects#12`).
   They are fragments; native panics *"no 'main' binding found"* and the browser
   answers `W-MAIN-MISSING`.
2. **does it import a module the page SHIPS?** `10-tooling-and-workflow#5` does
   `import test`, and `test` is deliberately excluded from `EXTRA_MODULES`
   (native-only externs). The current rule only inspects stubbed *calls*, never
   unshipped *imports*.

The differential deliberately does **not** patch that rule — it reports the gap
and recomputes the rule independently of `render_docs.mjs`, so a future
render/rule drift shows up as `MISCLASSIFIED` rather than as silent agreement.

⚠️ Not enrolled in `test/gates.toml`: it needs a built `playground.wasm`, and it
is currently RED by design (the nine above are real). Enrolling a red gate needs
a `known-red` issue and the `[W-SHARD-DERIVED]` cost-baseline dance — the
orchestrator's call once the three compiler bugs are filed.

## `SITE=1` — the e2e harness serves the deployed tree

`playground/e2e` used to serve `playground/` (the dev tree) and never
`playground/site/`, which is why it stayed green through a `build_site.sh` that
shipped a broken site. `SITE=1 bash playground/e2e/run.sh` now serves
`playground/site/` and makes the guide-route checks mandatory
(`E2E_EXPECT_GUIDE`); a missing or guide-less `site/` fails loud rather than
falling back. Both modes drive the SAME `playground/server.js` via its new
`SERVE_ROOT` env var, so there is only one MIME map and one cache policy.

`.github/workflows/nightly.yml`'s `playground-e2e` job now assembles
`playground/site/` (`bash playground/build_site.sh`) and runs the harness as
`SITE=1 bash playground/e2e/run.sh`, so the guide-route assertions genuinely
execute nightly rather than taking their skip branch. Still nightly-only: no PR
job runs this harness (`test/preflight.sh` keeps `playground/e2e/run.sh` in
`LOCAL_SKIP`), and the PR-gating guide check remains the static
`test/diff_compiler_guide_render.sh`.

⚠️ `GET /guide/` is a **404**: `build_site.sh` emits one page per chapter and no
directory index, and `playground/index.html` links to
`./guide/00-introduction.html` directly. Intentional as built, but a reader who
types `/guide/` gets nothing — worth a decision rather than a discovery.
