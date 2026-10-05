// render_docs.mjs — the ONE Markdown→HTML render machine for the Medaka site.
//
// Renders every `.md` file in a doc-set directory into a standalone HTML page,
// using the committed `marked` bundle at vendor/marked/marked.js (no network, no
// npm install at render time).
//
// It is deliberately doc-set-agnostic: the input directory is an argument, so the
// same generator serves docs/guide today and the ~28-page stdlib reference later
// (#2384) without a second implementation.
//
//   node render_docs.mjs --src <dir> --out <dir> [options]
//
// Options
//   --src <dir>        input directory to enumerate `*.md` from   (required)
//   --out <dir>        output directory for the rendered pages    (required)
//   --exclude <a,b>    basenames NOT to render (still link-rewritable? no — an
//                      excluded page is not in the rendered set, so links to it
//                      fall through to the external rule below)
//   --title <text>     doc-set title, used in <title> and the page header
//   --repo-url <url>   base URL that repo-relative links which leave the doc set
//                      are rewritten against (default: the GitHub blob URL for
//                      `main`). Pass `--repo-url ''` to leave them untouched.
//   --repo-root <dir>  repo root used to resolve those out-of-set links
//                      (default: the parent of this script's directory)
//   --playground-url <href>  href to the playground's index.html from a
//                      rendered page, used for the "open in playground" links
//                      and the back-to-playground nav (default: '../index.html')
//   --css-name <file>  basename of the stylesheet this doc set emits and links
//                      (default: 'guide.css'). Two doc sets rendered into the
//                      same directory must not both claim one filename.
//   --sibling <name>=<href>  a SIBLING doc set rendered beside this one: a link
//                      to `../<name>/X.md` (a page of `docs/<name>/`, resolved
//                      from the source's parent) is rewritten to `<href>/X.html`
//                      instead of to the repository, so the guide and the
//                      advanced topics reach each other's rendered pages. The
//                      source page must exist; a link to a missing one still
//                      falls through to the repository rule (and `make
//                      docs-links` refuses it). Repeatable.
//   --sibling-exclude <name>=<a,b>  basenames of that sibling's SOURCE pages its
//                      own builder does not render (the guide's OUTLINE.md, the
//                      stdlib notes). A link to one of them is not a page on the
//                      site, so it takes the repository rule like any other
//                      out-of-set link. Repeatable; must name a declared sibling.
//   --dist <dir>       the directory of `.mdk` modules the playground page SHIPS
//                      (playground/dist, staged by build_playground_wasm.sh).
//                      Optional: given, a block importing a module that is not
//                      there is classified not-runnable (conjunct 4 below);
//                      omitted, that one conjunct is skipped and everything else
//                      is unchanged.
//   --no-run-links     emit no "open in playground" footer under Medaka blocks
//                      (a doc set of prose whose code is illustration, not lessons).
//   --site-url <url>   the ABSOLUTE url this doc set is served at (e.g.
//                      https://medaka-lang.dev/guide). Given, every page gets
//                      link-preview tags (og:*, twitter:card) so a shared link
//                      renders a card; scrapers do not resolve relative urls.
//   --og-image <url>   absolute url of the 1200x630 card image; needs --site-url.
//   --og-image-alt <text>  alt text for that image.
//   --no-pager         omit the previous/next links at the foot of each page
//                      (a doc set whose pages are not read in order, like a blog).
//   --no-toc           omit the "On this page" box above each page's article.
//
// A page's og:description is the `<!-- description: … -->` comment in its source
// when there is one, else its first prose paragraph; `<!-- og-image: <file> -->`
// gives that page its own card image, relative to --site-url, and
// `<!-- og-image-alt: … -->` its alt text.
//
// Besides one page per source `.md`, the renderer emits a doc-set INDEX page at
// `index.html`: a static host serves nothing at a bare directory URL without
// one, so `/guide/` would 404 for anyone who types the route rather than
// following a link into a specific chapter.
//
// Output contract (S-2 "open in playground" links and S-3 site wiring depend on
// this shape — see playground/NOTES.md):
//
//   <div class="codeblock" data-lang="medaka" data-fence="medaka"
//        data-source="<HTML-escaped raw fence body>">
//     <pre><code class="language-medaka">…escaped source…</code></pre>
//   </div>
//
// `data-source` carries the exact fence body, so a later pass can recover the
// program text without re-parsing the Markdown. `data-lang` is the normalized
// fence label (the token before any `:` or whitespace); `data-fence` is the raw
// info string.
//
// Fence labels are a CLOSED SET (KNOWN_FENCES below). An unknown label is a hard
// error, not a silent fall-through to unhighlighted prose: a doc that grows a new
// fence kind must teach this renderer about it.

import { readdirSync, readFileSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join, resolve, dirname, basename, relative, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Marked } from './vendor/marked/marked.js';
import { highlightMedaka } from './highlight_medaka.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

// ── fence labels ────────────────────────────────────────────────────────────
// Every label the doc corpus uses, with the CSS class the block gets. `medaka*`
// blocks are Medaka source in one of four dispositions; `toml` is a manifest.
const KNOWN_FENCES = {
  'medaka': 'medaka',            // a complete, checkable program
  'medaka-expect': 'output',     // the expected stdout of the block above it
  'medaka-project': 'medaka',    // a multi-file project listing
  'medaka-nocheck': 'medaka',    // a fragment, deliberately not standalone
  'toml': 'toml',                // a medaka.toml manifest
  '': 'plain',                   // an unlabelled fence (shell transcripts, trees)
};

// ── tiny helpers ────────────────────────────────────────────────────────────
const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
   .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// ── "open in playground" runnability partition ─────────────────────────────
// A fenced block is RUNNABLE in the browser playground iff ALL of:
//   1. its normalized fence label is exactly `medaka` (not `medaka-project` —
//      multi-file, the playground has one buffer; not `medaka-nocheck` — a
//      fragment never meant to stand alone; and not `medaka-expect`/`toml`/an
//      unlabelled fence, none of which are Medaka source to run at all), AND
//   2. its source contains no call to a host capability the playground's wasm
//      import object stubs out (playground/worker.js `capabilityStub`):
//      readFile, writeFile, readLine, readLines, getEnv, fileExists, args,
//      exit. Calling one of these does not fail to COMPILE — the wasm module
//      loads fine — it throws a `CapabilityError` at run time instead of
//      producing the documented output, which is worse than no link.
//   3. it defines a top-level `main`. A block without one is not a program:
//      natively `medaka run`/`build` refuse it with one located error
//      (W-MAIN-MISSING), and the browser answers the same code. The ▶ button would open a guaranteed
//      failure, so there must not be one.
//   4. every module it imports is one the page SHIPS. A `import test` resolves
//      natively and 404s in the browser, which fetches each import from
//      `dist/<id>.mdk`. The shipped set is DERIVED from a `--dist` directory,
//      never hardcoded; with no `--dist` this conjunct is skipped (a caller that
//      does not know which modules its page ships cannot be asked to assert
//      anything about them — see parseArgs).
// Everything outside that partition gets a deliberate, visible "not runnable"
// note instead of a link — never a silently absent one. See playground/NOTES.md
// for the corpus counts this partition currently produces.
//
// ⚠️ Conjuncts 3 and 4 are also stated, INDEPENDENTLY, by
// playground/guide_wasm_differential.mjs (`ruleSaysRunnable` there, plus its
// `definesMain`/`unshippedImports`). That duplication is deliberate — a shared
// constant cannot disagree with itself, and the differential's job is to catch
// the render and the rule drifting apart — so a change here needs the mirror
// there.
const UNSUPPORTED_CALL_RE =
  /\b(readFile|writeFile|readLine|readLines|getEnv|fileExists|args|exit)\b/;

// Conjunct 3. A top-level `main` binding starts a line, so anchor to one.
const definesMain = (text) => /^main\b/m.test(text);

// Conjunct 4. Top-level `import <module>` — the module id is the first
// lowercase token after the keyword; the selective/alias/wildcard tail is
// irrelevant to WHICH file the page must have fetched.
function unshippedImports(text, shipped) {
  const out = [];
  for (const m of text.matchAll(/^\s*(?:export\s+)?import\s+([a-z][a-z_0-9]*)/gm)) {
    if (!shipped.has(m[1])) out.push(m[1]);
  }
  return out;
}

// The shipped-module set, DERIVED from what build_playground_wasm.sh staged —
// exactly the files main.js can fetch as `dist/<id>.mdk`. `null`/absent means
// "this caller does not know the shipped set", which SKIPS conjunct 4; an empty
// directory would be a legitimately empty set and is NOT the same thing.
//
// Exported because a caller that wants to RECOMPUTE `classifyRunnable` over an
// already-rendered page (playground/guide_render_test.mjs check 8) must feed it
// the identical set the render used — deriving it a second time by hand is
// exactly the drift that check exists to catch.
export function shippedModules(distDir) {
  return distDir === null || distDir === undefined
    ? null
    : new Set(readdirSync(distDir).filter((f) => f.endsWith('.mdk')).map((f) => f.replace(/\.mdk$/, '')));
}

export function classifyRunnable(label, text, shipped) {
  if (label === 'medaka-project') {
    return { runnable: false, reason: 'multi-file project — the playground runs a single source buffer' };
  }
  if (label === 'medaka-nocheck') {
    return { runnable: false, reason: 'a fragment, not a standalone program' };
  }
  const m = text.match(UNSUPPORTED_CALL_RE);
  if (m) {
    return { runnable: false, reason: `uses \`${m[1]}\`, which the browser playground has no host support for` };
  }
  if (!definesMain(text)) {
    return { runnable: false, reason: 'defines no top-level `main`, so there is no program to run' };
  }
  if (shipped) {
    const missing = unshippedImports(text, shipped);
    if (missing.length) {
      return { runnable: false,
        reason: `imports \`${missing.join('`, `')}\`, which the playground does not ship` };
    }
  }
  return { runnable: true };
}

// Mirrors playground/main.js `encodeProgram` byte-for-byte: UTF-8 bytes -> base64
// -> URL-safe (`+`->`-`, `/`->`_`, trailing `=` stripped). A pure string
// transform, so the build can compute it without any browser runtime.
function encodeProgram(src) {
  return Buffer.from(src, 'utf8').toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ── doctest fences ──────────────────────────────────────────────────────────
// `medaka doc` publishes every doctest as a `medaka` fence whose first line is
// the `> expr` prompt — `renderDocSegment (ExampleSeg ls)`, compiler/tools/
// doc.mdk, and an `ExampleSeg` starts at a `> ` line by construction
// (`isExampleStart`). A Medaka program cannot begin with `> `, so the prompt is
// a structural signal from the generator's own output, and it is the ONLY
// signal this renderer is allowed to use here: a doctest fence is one shaped
// as a transcript, never one that happens to live under `docs/stdlib` (a
// `--src`/doc-set comparison would be a per-caller flag, and would misclassify
// the identical construct anywhere else it appears).
//
// Val ruling (#2384): a doctest gets NO runnability footer at all — neither a
// ▶ link nor a "not runnable" note. It is a transcript of an expression and its
// value (`> range 2 5` / `[2, 3, 4]`), verified on every `medaka test` run; it
// was never a program, so "not runnable in the playground" is noise, and the
// prose already says what runs it. This suppresses the footer ELEMENT only —
// `classifyRunnable` still classifies these fences exactly as before (they
// define no top-level `main`), and every other not-runnable fence, the guide's
// 67 `medaka` fragments included, keeps its note.
export const DOCTEST_PROMPT = /^> /;

// Mark each top-level `code` token that is a doctest transcript. Run as
// marked's `processAllTokens` hook so the classification lives in one place
// the `code` renderer and any test can share.
export function markDoctestFences(tokens) {
  for (const tok of tokens) {
    if (tok.type === 'code') {
      tok.isDoctest = (tok.lang ?? '').trim() === 'medaka' && DOCTEST_PROMPT.test(tok.text);
    }
  }
  return tokens;
}

function runnableFooter(status, text, playgroundUrl) {
  if (status.runnable) {
    const href = `${playgroundUrl}#code=${encodeProgram(text)}`;
    return `<div class="codeblock-actions">`
      + `<a class="pg-run" href="${escapeHtml(href)}" rel="noopener">&#9654; Open in Playground</a>`
      + `</div>`;
  }
  return `<div class="codeblock-actions">`
    + `<span class="pg-not-runnable">Not runnable in the playground: ${escapeHtml(status.reason)}</span>`
    + `</div>`;
}

// The inverse of `escapeHtml`, plus the handful of named entities an author may
// have typed literally in Markdown. Heading text reaches the slugger already
// HTML-escaped (marked's `parseInline` escapes as it renders), so without this
// the `[^\w\s-]` strip below sees `&quot;` as the five bare letters `quot` and
// welds them into the anchor — `#quothello-worldquot-in-medaka`. Decode FIRST,
// so the punctuation is punctuation again and gets stripped as punctuation.
// `&amp;` is decoded LAST: doing it first would let `&amp;lt;` become `<`.
export const decodeEntities = (s) =>
  s.replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
   .replace(/&#[xX]([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
   .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
   .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
   .replace(/&nbsp;/g, ' ')
   .replace(/&amp;/g, '&');

// Slug from heading TEXT, GitHub-flavoured: lowercase, drop everything that is
// not a word char / space / hyphen, spaces → hyphens. Collision-safe via a
// per-page seen-count suffix, so two identically-titled headings get stable,
// distinct anchors in document order.
function slugger() {
  const seen = new Map();
  return (text) => {
    const base = decodeEntities(text.replace(/<[^>]*>/g, '')).toLowerCase().trim()
      .replace(/[^\w\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '') || 'section';
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    return n === 0 ? base : `${base}-${n}`;
  };
}

function parseArgs(argv) {
  const opts = {
    src: null, out: null, exclude: [], title: null,
    repoUrl: 'https://github.com/MedakaLang/medaka/blob/main',
    repoRoot: resolve(HERE, '..'),
    // Relative (or absolute) href to the playground's index.html, from a
    // rendered page. Default assumes the convention `build_site.sh` (S-3) is
    // expected to follow: this doc set's pages land one directory below the
    // playground root (e.g. site/guide/*.html next to site/index.html).
    playgroundUrl: '../index.html',
    cssName: 'guide.css',
    // Extra header links, rendered after the doc-set title in the order given.
    // Each is Label=href; hrefs are relative to a rendered page, like
    // --playground-url. The renderer knows nothing about sibling doc sets, so
    // the caller that lays them out beside each other supplies the links.
    navLinks: [],
    // false = no "open in playground" footer under any Medaka block (--no-run-links).
    runLinks: true,
    // Absolute base url + card image for link-preview tags; null = no tags.
    siteUrl: null,
    ogImage: null,
    ogImageAlt: '',
    // false = no previous/next links at the foot of a page (--no-pager).
    pager: true,
    // false = no "On this page" box (--no-toc).
    toc: true,
    // Sibling doc sets, {name, href, exclude}: see --sibling above. Empty = every
    // out-of-set link goes to the repository, exactly as before.
    siblings: [],
    // null = "this caller does not know the shipped-module set", which SKIPS the
    // unshipped-import conjunct rather than asserting an empty set (which would
    // call every importing block not-runnable). Same default-preserves-behavior
    // discipline as --css-name.
    distDir: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case '--src': opts.src = resolve(next()); break;
      case '--out': opts.out = resolve(next()); break;
      case '--exclude': opts.exclude = next().split(',').map((s) => s.trim()).filter(Boolean); break;
      case '--title': opts.title = next(); break;
      case '--repo-url': opts.repoUrl = next().replace(/\/+$/, ''); break;
      case '--repo-root': opts.repoRoot = resolve(next()); break;
      case '--playground-url': opts.playgroundUrl = next(); break;
      case '--css-name': opts.cssName = next(); break;
      case '--nav-link': {
        const v = next();
        const eq = v.indexOf('=');
        if (eq <= 0 || eq === v.length - 1) throw new Error(`--nav-link needs Label=href, got: ${v}`);
        opts.navLinks.push({ label: v.slice(0, eq), href: v.slice(eq + 1) });
        break;
      }
      case '--sibling': {
        const v = next();
        const eq = v.indexOf('=');
        if (eq <= 0 || eq === v.length - 1) throw new Error(`--sibling needs name=href, got: ${v}`);
        const name = v.slice(0, eq);
        if (name.includes('/') || name.includes('\\')) {
          throw new Error(`--sibling name must be a bare directory name under docs/, not a path: ${name}`);
        }
        opts.siblings.push({ name, href: v.slice(eq + 1).replace(/\/+$/, ''), exclude: [] });
        break;
      }
      case '--sibling-exclude': {
        const v = next();
        const eq = v.indexOf('=');
        if (eq <= 0 || eq === v.length - 1) throw new Error(`--sibling-exclude needs name=a,b, got: ${v}`);
        const name = v.slice(0, eq);
        const sib = opts.siblings.find((s) => s.name === name);
        if (!sib) throw new Error(`--sibling-exclude names \`${name}\`, which no earlier --sibling declared`);
        sib.exclude.push(...v.slice(eq + 1).split(',').map((s) => s.trim()).filter(Boolean));
        break;
      }
      case '--dist': opts.distDir = resolve(next()); break;
      case '--no-run-links': opts.runLinks = false; break;
      case '--site-url': opts.siteUrl = next().replace(/\/+$/, ''); break;
      case '--og-image': opts.ogImage = next(); break;
      case '--og-image-alt': opts.ogImageAlt = next(); break;
      case '--no-pager': opts.pager = false; break;
      case '--no-toc': opts.toc = false; break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!opts.src || !opts.out) throw new Error('both --src and --out are required');
  if (opts.cssName.includes('/') || opts.cssName.includes('\\')) {
    throw new Error(`--css-name must be a bare filename, not a path: ${opts.cssName}`);
  }
  // A --dist that is not there is a hard error, never a silent skip: the caller
  // asked for the check, so failing to perform it must be loud.
  for (const [flag, v] of [['--site-url', opts.siteUrl], ['--og-image', opts.ogImage]]) {
    if (v !== null && !/^https?:\/\//.test(v)) throw new Error(`${flag} must be an absolute url, got: ${v}`);
  }
  if (opts.ogImage && !opts.siteUrl) throw new Error('--og-image needs --site-url');
  if (opts.distDir && !existsSync(opts.distDir)) {
    throw new Error(`--dist does not exist: ${opts.distDir}`);
  }
  return opts;
}

// ── the renderer ────────────────────────────────────────────────────────────
export function renderDocSet(opts) {
  const { src, out, exclude, repoUrl, repoRoot, playgroundUrl = '../index.html',
          cssName = 'guide.css', navLinks = [], siblings = [], distDir = null, runLinks = true, siteUrl = null, ogImage = null, ogImageAlt = '', pager = true, toc: showToc = true } = opts;
  const og = siteUrl ? { siteUrl, ogImage, ogImageAlt } : null;
  if (!existsSync(src)) throw new Error(`--src does not exist: ${src}`);

  // A sibling doc set's SOURCE directory sits beside this one (docs/guide next
  // to docs/advanced), so it is resolved from the source's parent, never from
  // the repo root: pointing the renderer at a scratch copy of a doc set keeps
  // its siblings scratch-relative too.
  const siblingDirs = siblings.map(({ name, href, exclude = [] }) =>
    ({ dir: resolve(src, '..', name), href, exclude: new Set(exclude) }));

  const shipped = shippedModules(distDir);

  // Enumerate the doc set from the DIRECTORY — never a hardcoded chapter list, so
  // a new chapter appears on the site by existing.
  const pages = readdirSync(src)
    .filter((f) => f.endsWith('.md'))
    .filter((f) => !exclude.includes(f))
    .sort();
  if (pages.length === 0) throw new Error(`no .md files to render in ${src}`);

  // The rendered set, by source basename — the link rewriter's authority for
  // "is this target one of my own pages?".
  const inSet = new Set(pages);
  const docTitle = opts.title ?? basename(src);

  // Chapter titles come from each page's H1, not its filename: the sidebar
  // shows "Quick Start", never "01-quick-start". Read up front so the shell of
  // the first page already knows the title of the last.
  const titles = new Map(pages.map((file) => [file, pageTitleOf(readFileSync(join(src, file), 'utf8'), file)]));

  const rendered = pages.map((file) =>
    renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages, titles, playgroundUrl, navLinks, cssName, shipped, siblingDirs, runLinks, og, pager, showToc }));

  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const page of rendered) writeFileSync(join(out, page.outFile), page.html);
  // The doc-set index. A static host serves a directory URL from its index.html
  // or not at all, so without this the bare `/guide/` route is a 404 even though
  // every chapter page is present — see playground/NOTES.md.
  //
  // ⚠️ Only when the doc set does NOT supply one. `docs/guide` has no
  // `index.md`, so the synthetic contents page is the only candidate there; the
  // stdlib reference (#2384) DOES ship one — `docs/stdlib/index.md`, ~905
  // per-entry deep links generated by `medaka doc` — and it renders to
  // `index.html` like any other page. Writing the synthetic page
  // unconditionally overwrote that, silently replacing every deep link with a
  // 31-item chapter list. A doc set that authors its own index wins: it is
  // strictly more informative than a list this renderer can synthesize from
  // basenames, and the renderer must not clobber generated content.
  if (!inSet.has('index.md')) {
    writeFileSync(join(out, 'index.html'),
      indexPage({ docTitle, rendered, pages, titles, playgroundUrl, navLinks, cssName, og }));
  }
  writeFileSync(join(out, cssName), STYLESHEET);

  return rendered;
}

// A page's title is its first H1 with inline code marks stripped (`do` and
// Thenables -> do and Thenables); the basename is the fallback for a page with
// no H1 at all.
function pageTitleOf(markdown, file) {
  return (markdown.match(/^#\s+(.+)$/m)?.[1] ?? basename(file, '.md')).replace(/`/g, '').trim();
}

function renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages, titles, playgroundUrl, navLinks, cssName, shipped, siblingDirs = [], runLinks = true, og = null, pager = true, showToc = true }) {
  const markdown = readFileSync(join(src, file), 'utf8');
  const slug = slugger();
  const toc = [];
  const md = new Marked({ gfm: true, breaks: false });
  // Errors are COLLECTED, not thrown from inside a renderer hook: marked wraps a
  // throw from a hook with "Please report this to markedjs/marked", which points
  // a reader at the wrong project. We report them all ourselves after the parse.
  const errors = [];

  md.use({
    hooks: { processAllTokens: markDoctestFences },
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const plain = this.parser.parseInline(tokens).replace(/<[^>]*>/g, '');
        const id = slug(plain);
        if (depth >= 2 && depth <= 3) toc.push({ id, depth, text: plain });
        return `<h${depth} id="${id}">`
          + `<a class="anchor" href="#${id}" aria-label="Permalink">#</a>${text}`
          + `</h${depth}>\n`;
      },

      code({ text, lang, isDoctest }) {
        const info = (lang ?? '').trim();
        // `medaka-nocheck: some prose about why` — the label is the token before
        // any `:` or whitespace; the rest is a human note.
        const label = info.split(/[\s:]/, 1)[0];
        if (!(label in KNOWN_FENCES)) {
          errors.push(
            `${file}: unknown fence label \`${label}\` (info string: \`${info}\`). ` +
            `Teach playground/render_docs.mjs about it — an unknown label must not ` +
            `silently render as unhighlighted prose.`);
        }
        const kind = KNOWN_FENCES[label] ?? 'unknown';
        const footer = kind === 'medaka' && !isDoctest && runLinks
          ? runnableFooter(classifyRunnable(label, text, shipped), text, playgroundUrl)
          : '';
        return `<div class="codeblock kind-${kind}"`
          + ` data-lang="${escapeHtml(label || 'plain')}"`
          + ` data-fence="${escapeHtml(info)}"`
          + ` data-source="${escapeHtml(text)}">`
          + `<pre tabindex="0"><code class="language-${escapeHtml(label || 'plain')}">`
          // Only real Medaka source is highlighted. `kind === 'medaka'` covers
          // `medaka`/`medaka-project`/`medaka-nocheck` (KNOWN_FENCES above);
          // `medaka-expect` is documented stdout, not source, and `toml`/`plain`
          // are neither — all three keep the flat plain-escaped body. The
          // `data-source` attribute above is ALWAYS `escapeHtml(text)`, never
          // highlighted: it is what the playground round-trip and the wasm
          // differential read back as the block's source.
          + `${kind === 'medaka' ? highlightMedaka(text) : escapeHtml(text)}</code></pre>${footer}</div>\n`;
      },

      link({ href, title, tokens }) {
        const body = this.parser.parseInline(tokens);
        const rewritten = rewriteHref(href, { file, src, inSet, repoUrl, repoRoot, errors, siblingDirs });
        const t = title ? ` title="${escapeHtml(title)}"` : '';
        const ext = /^https?:/.test(rewritten) ? ' rel="noopener"' : '';
        return `<a href="${escapeHtml(rewritten)}"${t}${ext}>${body}</a>`;
      },
    },
  });

  const body = md.parse(markdown);
  if (errors.length > 0) throw new Error(errors.join('\n  '));
  const outFile = file.replace(/\.md$/, '.html');
  const pageTitle = titles.get(file);

  return {
    srcFile: file,
    outFile,
    title: pageTitle,
    toc,
    html: pageShell({ pageTitle, docTitle, body, toc: showToc ? toc : [], outFile, pages, titles, playgroundUrl, navLinks, cssName,
                      og: pageOg(og, markdown), description: pageDescription(markdown), pager }),
  };
}

// A page's own card image, `<!-- og-image: <file> -->`, resolved against the doc
// set's --site-url, replaces the doc set's --og-image for that page alone.
function pageOg(og, markdown) {
  const own = markdown.match(/<!--\s*og-image:\s*(\S+)\s*-->/);
  if (!og || !own) return og;
  const url = /^https?:\/\//.test(own[1]) ? own[1] : `${og.siteUrl}/${own[1]}`;
  const alt = markdown.match(/<!--\s*og-image-alt:\s*([\s\S]*?)-->/);
  return { ...og, ogImage: url, ogImageAlt: alt ? alt[1].trim() : og.ogImageAlt };
}

// A page's link-preview description: its `<!-- description: … -->` comment, else
// the first prose paragraph with the Markdown syntax stripped, cut at a word
// boundary near 200 characters.
export function pageDescription(markdown) {
  const explicit = markdown.match(/<!--\s*description:\s*([\s\S]*?)-->/);
  const paragraph = explicit ? explicit[1]
    : (markdown.split(/\n\s*\n/).map((b) => b.trim())
        .find((b) => b !== '' && !/^(#|```|<|>|-|\*|\||\d+\.)/.test(b)) ?? '');
  const plain = paragraph
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[`*_]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (plain.length <= 200) return plain;
  return plain.slice(0, 200).replace(/\s+\S*$/, '') + '…';
}

// Rewrite one href.
//   - in-set `.md` (optionally with a #fragment)  → the sibling `.html` page
//   - a page of a --sibling doc set               → that set's rendered page
//   - out-of-set repo-relative path               → repoUrl + the repo-relative path
//   - anything else (absolute URL, bare #anchor)  → untouched
//
// The SOURCE `.md` files are never edited — `make docs-links` gates those, and the
// rewrite lives entirely in the rendered output.
function rewriteHref(href, { file, src, inSet, repoUrl, repoRoot, errors, siblingDirs = [] }) {
  if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('//')) {
    return href;
  }
  const hash = href.indexOf('#');
  const path = hash === -1 ? href : href.slice(0, hash);
  const frag = hash === -1 ? '' : href.slice(hash);
  if (!path) return href;

  // A bare sibling name that is one of our own rendered pages.
  if (!path.includes('/') && path.endsWith('.md')) {
    if (!inSet.has(path)) {
      // A cross-chapter link naming a sibling that is not in the rendered set is
      // a BROKEN link, not an out-of-set one. Falling through to the repository
      // rewrite below would quietly turn it into a plausible-looking GitHub URL
      // that 404s, so refuse instead.
      errors.push(
        `${file}: cross-chapter link \`${href}\` names \`${path}\`, which is not ` +
        `in the rendered doc set (missing, or excluded from rendering).`);
      return href;
    }
    return path.replace(/\.md$/, '.html') + frag;
  }

  const abs = resolve(dirname(join(src, file)), path);

  // A page of a sibling doc set rendered beside this one (--sibling): the
  // guide's ../advanced/effects-1-rows.md is a rendered page at
  // ../advanced/effects-1-rows.html on the deployed site. Only a `.md` DIRECTLY
  // inside the sibling's directory qualifies, and only if it exists and the
  // sibling's builder renders it (--sibling-exclude) — a missing or unrendered
  // one falls through to the repository rule below rather than becoming a
  // plausible-looking 404 on our own site.
  if (path.endsWith('.md')) {
    for (const { dir, href: base, exclude } of siblingDirs) {
      if (dirname(abs) === dir && existsSync(abs) && !exclude.has(basename(abs))) {
        return `${base}/${basename(abs).replace(/\.md$/, '.html')}${frag}`;
      }
    }
  }

  // Everything else relative points OUT of the doc set (../spec/SYNTAX.md,
  // ../../stdlib/core.mdk, …). Those pages are not rendered here, so a `.html`
  // rewrite would manufacture a 404; send them at the repository instead.
  if (!repoUrl) return href;
  const rel = relative(repoRoot, abs);
  if (rel.startsWith('..')) return href;   // escapes the repo — leave it alone
  return `${repoUrl}/${rel.split(/[\\/]/).join(posix.sep)}${frag}`;
}

// ── page shell ──────────────────────────────────────────────────────────────
function pageShell({ pageTitle, docTitle, body, toc, outFile, pages, titles, playgroundUrl, navLinks = [], cssName = 'guide.css',
                    og = null, description = '', pager = false }) {
  // Previous/next follow the sidebar's chapter order; an authored index.md is
  // the doc set's landing page, not a chapter, so it is not in the sequence.
  const sequence = pages.filter((p) => p !== 'index.md');
  const at = sequence.findIndex((p) => p.replace(/\.md$/, '.html') === outFile);
  const step = (p, cls, label) => !p ? '' :
    `<a class="${cls}" href="${escapeHtml(p.replace(/\.md$/, '.html'))}">`
    + `<span class="pager-label">${label}</span>${escapeHtml(titles.get(p))}</a>`;
  const pagerHtml = !pager || at < 0 || sequence.length < 2 ? '' :
    `<nav class="pager" aria-label="Chapter">\n`
    + step(sequence[at - 1], 'pager-prev', '&larr; Previous')
    + step(sequence[at + 1], 'pager-next', 'Next &rarr;')
    + `\n</nav>\n`;
  const fullTitle = pageTitle === docTitle ? pageTitle : `${pageTitle} — ${docTitle}`;
  const ogHtml = !og ? '' : [
    `<meta name="description" content="${escapeHtml(description)}">`,
    `<meta property="og:type" content="article">`,
    `<meta property="og:url" content="${escapeHtml(`${og.siteUrl}/${outFile.replace(/(?:^|\/)index\.html$|\.html$/, "")}`)}">`,
    `<meta property="og:title" content="${escapeHtml(pageTitle)}">`,
    `<meta property="og:description" content="${escapeHtml(description)}">`,
    ...(og.ogImage ? [
      `<meta property="og:image" content="${escapeHtml(og.ogImage)}">`,
      `<meta property="og:image:width" content="1200">`,
      `<meta property="og:image:height" content="630">`,
      `<meta property="og:image:alt" content="${escapeHtml(og.ogImageAlt)}">`,
      `<meta name="twitter:card" content="summary_large_image">`,
    ] : []),
  ].join('\n') + '\n';
  // The link list is emitted twice: a row for wide viewports and, for phones, the
  // same links inside a <details> menu behind a hamburger. CSS shows exactly one
  // of the two at any width; a closed <details> cannot be forced open from CSS,
  // which is why the row is not simply restyled.
  const linksHtml = navLinks.map(({ label, href }) => {
    const ext = /^https?:\/\//.test(href) ? ' target="_blank" rel="noopener"' : '';
    return `<a href="${escapeHtml(href)}"${ext}>${escapeHtml(label)}</a>`;
  }).join('\n');
  const navHtml = navLinks.length === 0 ? '' :
    `<nav class="site-nav-links" aria-label="Site">\n${linksHtml}\n</nav>\n`
    + `<details class="site-nav-menu">\n<summary aria-label="Site menu">\u2630</summary>\n`
    + `<nav class="site-nav-menu-links" aria-label="Site">\n${linksHtml}\n</nav>\n</details>\n`;
  const tocHtml = toc.length === 0 ? '' :
    `<nav class="toc" aria-label="On this page">\n<h2>On this page</h2>\n<ul>\n`
    + toc.map((h) => `<li class="toc-h${h.depth}"><a href="#${h.id}">${h.text}</a></li>`).join('\n')
    + `\n</ul>\n</nav>\n`;

  const chapters = pages.map((p) => {
    const href = p.replace(/\.md$/, '.html');
    const here = href === outFile ? ' class="here" aria-current="page"' : '';
    return `<li><a href="${href}"${here}>${escapeHtml(titles.get(p))}</a></li>`;
  }).join('\n');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(fullTitle)}</title>
${ogHtml}<link rel="stylesheet" href="${escapeHtml(cssName)}">
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>
<header class="site-nav">
<a class="site-nav-back" href="${escapeHtml(playgroundUrl)}">&larr; Playground</a>
<a class="site-nav-title" href="index.html">${escapeHtml(docTitle)}</a>
${navHtml}</header>
<div class="layout">
<nav class="chapters" aria-label="Chapters">
<h2>${escapeHtml(docTitle)}</h2>
<ul>
${chapters}
</ul>
</nav>
<main id="main">
${tocHtml}<article>
${body}</article>
${pagerHtml}</main>
</div>
</body>
</html>
`;
}

// The doc-set index: a real contents page listing every rendered chapter by its
// own H1, in render order. It is SYNTHETIC — it has no source `.md` — so it is
// emitted rather than mapped from the source set, which also keeps every count
// that derives from `docs/guide/*.md` honest. It is written ONLY for a doc set
// with no `index.md` of its own (see the guard in `renderDocSet`): where a set
// authors one, that page is the index and this function is never called.
function indexPage({ docTitle, rendered, pages, titles, playgroundUrl, navLinks, cssName, og = null }) {
  const items = rendered.map((p) =>
    `<li><a href="${escapeHtml(p.outFile)}">${escapeHtml(p.title)}</a></li>`).join('\n');
  const body = `<h1>${escapeHtml(docTitle)}</h1>\n`
    + `<p>${escapeHtml(`${rendered.length} chapters. Start at the top, or jump in anywhere.`)}</p>\n`
    + `<ol class="chapter-index">\n${items}\n</ol>\n`;
  return pageShell({
    pageTitle: docTitle, docTitle, body, toc: [],
    outFile: 'index.html', pages, titles, playgroundUrl, navLinks, cssName, og,
    description: `${docTitle}: ${rendered.length} pages.`,
  });
}

// Design tokens copied VERBATIM from playground/index.html's `:root` (~line 39)
// — same dark chrome, same fixed (non-media-query) theme; the playground itself
// has no light-mode arm, so the guide doesn't invent one either.
const STYLESHEET = `/* Generated by playground/render_docs.mjs — do not edit by hand. */
:root {
  --bg: #121826;
  --panel: #181f30;
  --panel-2: #1e2638;
  --line: #2b3550;
  --ink: #e4e9f2;
  --muted: #9ba6ba;
  --faint: #8590a6;
  --accent: #5fd38f;
  --accent-bright: #8ee8b3;
  --accent-deep: #2fae68;
    --ok: #6fcf97;
  --err: #f47067;
  --code-bg: #0e1320;
  --mono: "SF Mono", "Cascadia Code", "Fira Code", Menlo, Consolas, monospace;
  --ui: system-ui, -apple-system, "Segoe UI", sans-serif;

  /* Syntax-highlighting palette, copied VERBATIM from the values in
     playground/medaka_lang.js's \`medakaHighlightStyle\` — the table CodeMirror
     paints the LIVE editor with. One token class per entry, same names the
     tokenizer returns, so a read-only guide block and the same code typed into
     the playground look identical. \`--tok-keyword\` sharing the accent family is
     deliberate continuity with the site chrome, not a duplicate to collapse:
     the two are free to diverge, and this block's job is to track the editor. */
  --tok-keyword: #5fd38f;
  --tok-comment: #8a94a6;
  --tok-string: #f0c674;
  --tok-character: #f0c674;
  --tok-interpolation: #ffb86c;
  --tok-escape: #ffb86c;
  --tok-number: #79c0ff;
  --tok-bool: #8ab4ff;
  --tok-typeName: #8ab4ff;
  --tok-constructor: #d29cf5;
  --tok-variableName: #d6dde8;
  --tok-operator: #a9b1ba;
  --tok-punctuation: #8b949e;
  --tok-typeVar: #6fc7d9;
  --tok-effectLabel: #f58fb0;
  --tok-effectVar: #b8c97a;
}
*, *::before, *::after { box-sizing: border-box; }
html { background: #0c1019; scroll-padding-top: 4.5rem; } /* clear the sticky .site-nav on #anchor jumps */
body { margin:0; color:var(--ink); background:var(--bg); font:16px/1.65 var(--ui); }
a { color:var(--accent); text-decoration:none; }
a:hover { color:var(--accent-bright); text-decoration:underline; }
/* Prose links are underlined so they are distinguishable without colour. */
article a:not(.pg-run):not(.anchor) { text-decoration:underline; text-decoration-thickness:1px;
       text-underline-offset:.18em; }
.skip-link { position:absolute; left:-999px; top:.5rem; z-index:30; padding:.5rem .75rem;
       background:var(--panel); color:var(--ink); border:1px solid var(--accent); border-radius:6px; }
.skip-link:focus { left:.75rem; }

.site-nav { display:flex; align-items:center; gap:1rem; padding:.85rem 1.25rem;
       background:var(--panel); border-bottom:1px solid var(--line); position:sticky; top:0;
       z-index:10; }
.site-nav-links { margin-left:auto; display:flex; gap:1rem; font-size:.8rem; }
.site-nav-links a { color:var(--muted); padding:.3rem 0; }
.site-nav-links a:hover { color:var(--accent); text-decoration:none; }
.site-nav-back { color:var(--muted); font:500 .85rem var(--ui); white-space:nowrap; padding:.3rem 0; }
.site-nav-back:hover { color:var(--ink); }
.site-nav-title:hover { color:var(--ink); text-decoration:none; }
.site-nav-title { color:var(--faint); font-size:.8rem; text-transform:uppercase;
       letter-spacing:.06em; padding:.3rem 0; }
.site-nav-menu { display:none; margin-left:auto; position:relative; }
.site-nav-menu summary { list-style:none; cursor:pointer; color:var(--muted); font-size:1.15rem;
       line-height:1; padding:.3rem .5rem; border:1px solid var(--line); border-radius:6px; }
.site-nav-menu summary::-webkit-details-marker { display:none; }
.site-nav-menu[open] summary { color:var(--ink); }
.site-nav-menu-links { position:absolute; right:0; top:calc(100% + .5rem); display:flex;
       flex-direction:column; gap:.7rem; min-width:11rem; padding:.8rem 1rem; font-size:.95rem;
       background:var(--panel); border:1px solid var(--line); border-radius:8px;
       box-shadow:0 8px 24px rgba(0,0,0,.35); z-index:20; }
.site-nav-menu-links a { color:var(--muted); padding:.25rem 0; }
.site-nav-menu-links a:hover { color:var(--accent); text-decoration:none; }
@media (max-width:700px) {
  /* One row, always: back link, the set title truncated, a hamburger. The full
     link row would overflow the viewport and make the whole page scroll sideways. */
  .site-nav { gap:.75rem; padding:.7rem 1rem; }
  .site-nav-links { display:none; }
  .site-nav-menu { display:block; }
  .site-nav-title { flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
}
.pager { display:flex; gap:1rem; margin-top:3rem; padding-top:1.25rem; border-top:1px solid var(--line); }
.pager a { flex:1; display:flex; flex-direction:column; gap:.2rem; padding:.75rem 1rem;
       border:1px solid var(--line); border-radius:8px; color:var(--ink); }
.pager a:hover { border-color:var(--accent); text-decoration:none; }
.pager-next { text-align:right; margin-left:auto; }
.pager-label { font-size:.75rem; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }

.layout { display:flex; gap:2.5rem; max-width:1180px; margin:0 auto; padding:2rem 1.25rem; }
.chapters { flex:0 0 15rem; font-size:.88rem; }
.chapters h2, .toc h2 { font-size:.75rem; text-transform:uppercase; letter-spacing:.06em;
       color:var(--faint); margin:0 0 .6rem; }
.chapters ul, .toc ul { list-style:none; margin:0; padding:0; }
.chapters li { margin:.1rem 0; }
.chapters a { color:var(--muted); display:inline-block; padding:.25rem 0; }
.chapters a:hover { color:var(--ink); }
.chapters a.here { color:var(--accent); font-weight:600; }
main { flex:1 1 auto; min-width:0; max-width:42rem; }

h1,h2,h3 { line-height:1.3; margin:2rem 0 .75rem; color:var(--ink); }
h1 { margin-top:0; font-size:1.7rem; }
h2 { font-size:1.3rem; border-bottom:1px solid var(--line); padding-bottom:.3rem; }
h3 { font-size:1.05rem; }
h1 .anchor, h2 .anchor, h3 .anchor { float:left; margin-left:-1.15em; padding-right:.3em;
       color:var(--faint); opacity:0; text-decoration:none; }
h1:hover .anchor, h2:hover .anchor, h3:hover .anchor { opacity:1; }
p, li { color:var(--ink); }

.toc { border:1px solid var(--line); background:var(--panel); border-radius:8px;
       padding:.85rem 1.1rem; margin-bottom:2rem; font-size:.88rem; }
.toc li { margin:0; }
.toc a { color:var(--muted); display:inline-block; padding:.25rem 0; }
.toc a:hover { color:var(--accent); }
.toc .toc-h3 { padding-left:1rem; }

.codeblock { margin:1.1rem 0; border:1px solid var(--line); border-radius:8px;
       overflow:hidden; background:var(--code-bg); }
.codeblock pre { margin:0; padding:.9rem 1.1rem; overflow-x:auto; background:var(--code-bg); }
.codeblock.kind-output pre { background:var(--panel-2); }
.codeblock.kind-output { border-color:var(--line); }

/* Token spans emitted by playground/highlight_medaka.mjs, on \`kind-medaka\`
   blocks only. \`comment\` also carries the italic \`medakaHighlightStyle\` gives
   it. Any class without a rule here would render as plain body text — i.e.
   silently unhighlighted — so this list must stay in step with the token census
   in medaka_tokenizer.js's header (highlight_medaka.mjs throws on a stray one). */
.codeblock .tok-keyword       { color:var(--tok-keyword); }
.codeblock .tok-comment       { color:var(--tok-comment); font-style:italic; }
.codeblock .tok-string        { color:var(--tok-string); }
.codeblock .tok-character     { color:var(--tok-character); }
.codeblock .tok-interpolation { color:var(--tok-interpolation); }
.codeblock .tok-escape        { color:var(--tok-escape); }
.codeblock .tok-number        { color:var(--tok-number); }
.codeblock .tok-bool          { color:var(--tok-bool); }
.codeblock .tok-typeName      { color:var(--tok-typeName); }
.codeblock .tok-constructor   { color:var(--tok-constructor); }
.codeblock .tok-variableName  { color:var(--tok-variableName); }
.codeblock .tok-operator      { color:var(--tok-operator); }
.codeblock .tok-punctuation   { color:var(--tok-punctuation); }
.codeblock .tok-typeVar     { color:var(--tok-typeVar); }
.codeblock .tok-effectLabel { color:var(--tok-effectLabel); }
.codeblock .tok-effectVar   { color:var(--tok-effectVar); }
code, pre { font-family:var(--mono); font-size:.88em; }
:not(pre) > code { background:var(--panel-2); color:var(--ink); padding:.15em .4em;
       border-radius:4px; }

.codeblock-actions { border-top:1px solid var(--line); background:var(--panel);
       padding:.5rem .9rem; font:500 .8rem var(--ui); }
.pg-run { color:var(--accent); display:inline-block; padding:.3rem 0; }
.pg-run:hover { color:var(--accent-bright); }
.pg-not-runnable { color:var(--faint); font-style:italic; }

.chapter-index { padding-left:1.4rem; }
.chapter-index li { margin:.45rem 0; }

table { border-collapse:collapse; }
th, td { border:1px solid var(--line); padding:.4rem .7rem; text-align:left; }
blockquote { margin:1.1rem 0; padding:.65rem 1.1rem; border:1px solid var(--line);
       border-left:3px solid var(--accent); border-radius:8px; background:var(--panel);
       color:var(--muted); }
blockquote > :first-child { margin-top:0; }
blockquote > :last-child { margin-bottom:0; }
@media (max-width:820px) {
  .layout { flex-direction:column; }
  /* Prose first on a phone; the chapter list follows the page instead of
     pushing it a full screen down. The header title links to the index. */
  .chapters { flex:none; order:2; margin-top:2rem; padding-top:1rem; border-top:1px solid var(--line); }
  main { max-width:none; }
}
`;

// ── CLI ─────────────────────────────────────────────────────────────────────
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const pages = renderDocSet(opts);
    for (const p of pages) console.log(`  ${p.srcFile} -> ${p.outFile}  (${p.toc.length} TOC entries)`);
    console.log(`rendered ${pages.length} page(s) into ${opts.out}`);
  } catch (err) {
    console.error(`render_docs: ${err.message}`);
    process.exit(1);
  }
}
